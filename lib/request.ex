defmodule Torrent.Request do
  @data_request_len 16384 # 2^14 is a common size
  @request_count 5 # how many request tries per received block
  @max_load 3 # max load on one peer
  @expire_time 5 # seconds until a request has to be answered

  def data_request_len do
    @data_request_len
  end

  def start_link() do
    { _, pid } = Task.start_link(fn ->
      Process.flag(:priority, :high)

      meta_info = Torrent.Metadata.wait_for_metadata()
      num_pieces = Torrent.Filehandler.num_pieces meta_info[:info] 
      last_piece_size = Torrent.Filehandler.last_piece_size meta_info[:info] 

      request_info = %{
        num_pieces: num_pieces,
        last_piece_size: last_piece_size,
        piece_length: meta_info[:info][:piece_length],
        endgame: false,
        request_index: 0,
        request_offset: 0,
        request_size: @data_request_len
      }

      manage_requests %{}, [], request_info
    end)
    pid
  end

  def next_block(request_info, pieces) do
    if request_info[:endgame] do
      if Enum.empty?(pieces) do
        Torrent.Logger.log :request, "all pieces received, requester shutting down.."
        send :writer, { :finished }
        wait_for_shutdown()
      else
        IO.puts "requesting again.."
        pieces |> Enum.shuffle() |> List.first()
      end
    else
      %{
        index: request_info[:request_index], 
        offset: request_info[:request_offset], 
        size: request_info[:request_size] 
      }
    end
  end

  def wait_for_shutdown() do
    receive do
      { _ } -> wait_for_shutdown()
    end
  end

  def raise_block_counter(request_info) do
    if request_info[:endgame] do
      request_info
    else
      cond do 
        last_block?(request_info) ->
          index = request_info[:request_index]
          request_info = put_in(request_info, [:request_index], index + 1)
          put_in(request_info, [:request_offset], 0)
          |> put_in([:request_size], block_size(request_info))

        true ->
          request_info = update_in(request_info, [:request_offset], &(&1 + @data_request_len))
          request_info = put_in(request_info, [:request_size], block_size(request_info))
      end
    end
  end

  def block_size(request_info) do
    if last_piece?(request_info) && last_block?(request_info) do
      size = request_info[:last_piece_size] - request_info[:request_offset]
      size = if size <= 0, do: @data_request_len, else: size
    else
      @data_request_len
    end
  end

  def manage_requests(peers, pieces, request_info) do
    peers = expire_requests(peers)
    receive do
      # add a new connection with its piece infos
      { :bitfield, connection, socket, bitfield } ->
        peers
        |> add_peer(connection, socket) 
        |> add_bitfield(connection, bitfield, request_info)
        |> manage_requests(pieces, request_info)

      # have message from peer
      { :piece, connection, socket, index } ->
        add_peer_info(peers, connection, socket, index)
        |> request(pieces, request_info)

      # choke or unchoke message
      { :state, connection, socket, state } ->
        # put_in(peers, [connection, :state], state)
        add_peer_state(peers, connection, state)
        |> request(pieces, request_info)

      # received block
      { :received, connection, index, offset } ->
        Torrent.Logger.log :request, "request for #{index}, #{offset} finished"
        pieces = received_block(pieces, index, offset)
        peers = dec_peer_load(peers, connection)
        request peers, pieces, request_info

      after 1_000 ->
        request peers, pieces, request_info
    end
  end

  def check_endgame(request_info, block) do
    request_info = if block[:index] == request_info[:num_pieces] do
      IO.puts "endgame true"
      put_in(request_info, [:endgame], true)
    else
      request_info
    end
  end

  def request(peers, pieces, request_info, count \\ @request_count) do
    if count == 0 do
      manage_requests peers, pieces, request_info
    else
      block = next_block(request_info, pieces)
      request_info = check_endgame(request_info, block)

      { connection, peer } = 
        peers_with_piece(peers, block[:index]) 
        |> Enum.shuffle()
        |> List.first()

      cond do 
        peer == nil ->
          request peers, pieces, request_info, count - 1
        true ->
          peers = 
            case send_block_request(peer[:socket], block) do
              :ok -> inc_peer_load(peers, connection)
              _ -> Map.pop(peers, connection) |> elem(1)
            end
          pieces = add_block(pieces, block)
          request_info = raise_block_counter(request_info)
          request peers, pieces, request_info, count - 1
      end
    end
  end

  def expire_requests(peers) do
    current = System.system_time(:seconds)
    expire_requests(peers, current, Map.keys(peers))
  end
  def expire_requests(peers, current, []) do peers end
  def expire_requests(peers, current, [ connection | connections ]) do
    update_in(peers, [connection, :load], &(Enum.filter(&1, fn(time) -> 
      current - time < @expire_time
    end))) |> expire_requests(current, connections)
  end

  def inc_peer_load(peers, connection) do
    update_in(peers, [connection, :load], &(&1 ++ [System.system_time(:seconds)]))
  end
  def dec_peer_load(peers, connection) do
    unless peers[connection] == nil || Enum.empty?(peers[connection][:load]) do
      min = peers[connection][:load] |> Enum.min(fn -> false end)
      update_in(peers, [connection, :load], &(List.delete(&1, min)))
    else
      peers
    end
  end

  def piece_length(request_info) do
    num_pieces = request_info[:num_pieces]
    if request_info[:request_index] != num_pieces - 1 do
      request_info[:piece_length]
    else
      request_info[:last_piece_size]
    end
  end

  def received_block(pieces, index, offset) do
    piece_index = 
      Enum.find_index(pieces, 
        fn(piece) -> piece[:index] == index && piece[:offset] == offset end)
    if piece_index == nil do
      pieces
    else
      List.pop_at(pieces, piece_index) |> elem(1)
    end
  end

  def add_block(pieces, block) do
    if Enum.member?(pieces, block) do
      pieces
    else
      pieces ++ [block]
    end
  end

  def add_peer(peers, connection, socket) do
    put_in(peers, [connection], 
           %{ state: :choked, socket: socket, load: [], pieces: [] } )
  end

  def add_peer_state(peers, connection, state) do
    if peers[connection] == nil do
      peers
    else
      put_in peers, [connection, :state], state
    end
  end

  def add_peer_info(peers, connection, socket, index) do
    if peers[connection] == nil do
      add_peer(peers, connection, socket)
      |> update_in([connection, :pieces], &(Enum.uniq(&1 ++ [index])))
    else
      update_in peers, [connection, :pieces], &(Enum.uniq(&1 ++ [index]))
    end
  end

  def peers_with_piece(peers, index) do
    new_peers = Enum.filter(peers, fn({connection, info}) -> 
      Enum.member?(info[:pieces], index) &&
      info[:state] == :unchoke &&
      length(info[:load]) < @max_load
    end)
    if Enum.empty?(new_peers) do
      [{nil, nil}]
    else
      new_peers
    end
  end

  def add_bitfield(peers, connection, bitfield, request_info) do
    add_bitfield(peers, connection, bitfield, 0, request_info[:num_pieces])
  end
  def add_bitfield(peers, connection, bitfield, index, max) do
    if index == max do
      peers
    else
      case Enum.at(bitfield, index) do
        "1" ->
          peers 
          |> update_in([connection, :pieces], &(&1 ++ [index]))
          |> add_bitfield(connection, bitfield, index + 1, max)
        "0" ->
          peers 
          |> add_bitfield(connection, bitfield, index + 1, max)
      end
    end
  end

  def last_piece?(request_info) do
    request_info[:num_pieces] - 1 == request_info[:request_index]
  end
  def last_block?(request_info) do
    piece_len = piece_length(request_info)
    request_info[:request_offset] + @data_request_len >= piece_len
  end

  def send_block_request(socket, piece) do
    %{ index: index, offset: offset, size: size } = piece
    send_block_request(socket, index, offset, size, :request)
  end
  def send_block_request(socket, index, offset, size, type) do
    req = request_query index, offset, size, type 
    socket |> Socket.Stream.send(req)
  end

  def request_query(index, offset, size, type) do
    request_length = 13 # length of packet
    id = if type == :request, do: 6, else: 8

    Torrent.Logger.log :request, 
      "sending request: index #{index}, offset: #{offset}, size: #{size}"

    << request_length :: 32 >>
    <> << id :: 8 >>
    <> << index :: 32 >>
    <> << offset :: 32 >>
    <> << size :: 32 >>
  end

end
