defmodule Torrent.Stream do

  @message_flags [
    { 0, :choke },
    { 1, :unchoke },
    { 2, :interested },
    { 3, :uninterested },
    { 4, :have },
    { 5, :bitfield },
    { 6, :request },
    { 7, :piece },
    { 8, :cancel },
    { 20, :extension },
  ]

  def leech(socket, info_structs, options) do
    # check if we have meta info, if not set a empty list
    info_structs = 
      cond do
        info_structs[:meta_info][:info] == nil ->
          put_in(info_structs, [:meta_info, :info], [])
        true -> 
          info_structs
      end

    send_interested(socket)
    pipe_message(socket, info_structs)
  end

  def send_interested(socket) do
    len = 1
    { id, _ } = List.keyfind(@message_flags, :interested, 1)
    message = << len :: 32 >> <> << id :: 8 >>
    socket |> Socket.Stream.send(message)
    socket
  end

  def cancel() do
    exit(:normal)
  end

  def piece(socket, len, info_structs) do
    index = socket |> recv_32_bit_int
    offset = socket |> recv_32_bit_int
    # IO.puts "received #{index} with offset: #{offset}"
    block = %{
      peer: info_structs[:peer],
      len: len - 9,
      data: socket |> recv_byte!(len - 9)
    }
    send :writer, { :put, block, index, offset }
    pipe_message(socket, info_structs)
  end

  def bitfield(socket, len, info_structs) do
    piece_list = socket 
                |> recv_byte!(len - 1) 
                |> Torrent.Parser.parse_bitfield

    send :request, 
      { :bitfield, info_structs[:peer], socket, piece_list }

    pipe_message(socket, info_structs)
  end

  def have(socket, info_structs) do
    index = socket |> recv_32_bit_int
    send :request, 
      { :piece, info_structs[:peer], index }
    pipe_message(socket, info_structs)
  end

  def unchoke(socket, info_structs) do
    send :request,
      { :state, info_structs[:peer], :unchoke }
    pipe_message(socket, info_structs)
  end

  def extension(socket, len, info_structs) do
    info_structs = 
      case Torrent.Extension.pipe_message(socket, len, info_structs) do
        { :handshake, extension_hash } -> 
          put_in(info_structs, [:extension_hash], extension_hash)
        { :downloading, data } -> 
          update_in(info_structs, [:meta_info, :info], &(&1 ++ [data]))
        { :meta_info, info } -> 
          info_structs = put_in(info_structs, [:meta_info, :info], info)
          send :metadata, { :meta_info, info_structs[:meta_info] }
          info_structs
      end
    pipe_message(socket, info_structs)
  end

  def pipe_message(socket, info_structs) do
    unless Process.info(self)[:messages] |> Enum.empty? do
      receive do
        { :received, index } ->
          # TODO: send have message
          IO.puts "sending have message"
          pipe_message(socket, info_structs)
        { :meta_info, meta_info } ->
          info_structs = put_in(info_structs, [:meta_info], meta_info)
          pipe_message(socket, info_structs)
      end
    else
      len = socket |> recv_32_bit_int
      id = socket |> recv_8_bit_int

      { _, flag } = List.keyfind(@message_flags, id, 0)
      case flag do
        :choke ->
          pipe_message(socket, info_structs)
        :unchoke ->
          unchoke(socket, info_structs)
        :interested ->
          pipe_message(socket, info_structs)
        :uninterested ->
          pipe_message(socket, info_structs)
        :have ->
          have(socket, info_structs)
        :bitfield ->
          bitfield(socket, len, info_structs)
        :request ->
          pipe_message(socket, info_structs)
        :piece ->
          piece(socket, len, info_structs)
        :cancel ->
          cancel()
        :extension -> # extension for metadata transfer
          extension(socket, len, info_structs)
      end
    end
  end

  def recv_8_bit_int(socket) do 
    socket |> recv_byte!(1) |> :binary.bin_to_list |> Enum.at(0) 
  end

  def recv_32_bit_int(socket) do
    socket |> recv_byte!(4) |> :binary.decode_unsigned
  end

  def recv_byte!(socket, count) do
    case socket |> Socket.Stream.recv(count) do
      { :error, _ } ->
        exit(:normal)
      { :ok, nil } ->
        exit(:normal)
      { :ok, message } ->
        message
    end
  end

end
