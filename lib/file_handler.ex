defmodule Torrent.Filehandler do

  def start_link(tracker_info, requester_pid, output_path) do
    meta_info = tracker_info["info"]
    file_info = %{
      have: 0,
      pieces_needed: num_pieces(meta_info), 
      blocks_in_piece: num_blocks_in_piece(meta_info),
      piece_info: meta_info["pieces"],
      requester_pid: requester_pid
    }

    { ok, pid } = Task.start_link(fn -> 
      manage_files( %{}, file_info )
    end)
    pid
  end

  defp manage_files(file_data, file_info) do
    receive do
      {:put, block, index, offset } ->
        { file_data, file_info } = file_data |> add_block(file_info, index, offset, block)
        if download_complete?(file_info) do
          write_file(file_data, file_info)
        else
          manage_files(file_data, file_info)
        end
    end
  end

  def add_block(file_data, file_info, index, offset, block) do
    file_data = 
      case file_data[index] do
        nil ->
          file_data |> Map.put(index, %{})
        _ ->
          file_data
      end

    put_in(file_data, [index, offset], block)
    |> verify_piece(file_info, index, block[:peer])
  end

  def verify_piece(file_data, file_info, index, from) do
    recv_block_len = file_data[index] |> Map.keys |> length
    if recv_block_len == file_info[:blocks_in_piece] do
      # TODO: move this somewhere else
      data = file_data[index] 
             |> Enum.sort_by(fn({offset, block}) -> offset end)
             |> Enum.map(fn({offset, block}) -> block[:data] end)
             |> Enum.join("")

      Torrent.Parser.validate_block(file_info[:piece_info], index, data)
      file_info = file_info |> Map.update!(:have, fn i -> i + 1 end)
      send file_info[:requester_pid], { :received, index, from }
      # IO.puts "Piece with index: #{index} verified"
    end
    { file_data, file_info }
  end

  def write_file(file_data, count) do
    require IEx
    IEx.pry
  end

  def mkdir_tmp do
    if !File.exists?("tmp") do
      # IO.puts "creating tmp file"
      File.mkdir("tmp")
    end
  end

  defp download_complete?(count) do
    # IO.puts "got #{count[:have]} from #{count[:pieces_needed]}"
    if count[:pieces_needed] + 1 == count[:have] do
      true
    else
      false
    end
  end

  def num_blocks(meta_info) do
    num_pieces(meta_info) * num_blocks_in_piece(meta_info)
    |> round
  end

  def num_blocks_in_piece(meta_info) do
    num = meta_info["piece length"] / Torrent.Request.data_request_len
    # round up
    if num == trunc(num) do
      num
    else
      trunc(num) + 1
    end
  end

  def num_pieces(meta_info) do
    meta_info["length"] / meta_info["piece length"]
    |> round
  end

  def last_block_size(meta_info) do
    piece_len = meta_info["piece length"]
    blocks_in_piece = num_blocks_in_piece(meta_info) - 1
    data_len = Torrent.Request.data_request_len
    piece_len - blocks_in_piece * data_len
  end

  def last_piece_size(meta_info) do 
    file_length = meta_info["length"] 
    piece_len = meta_info["piece length"] 
    num_pieces = num_pieces(meta_info)
    file_length - piece_len * num_pieces
  end

end
