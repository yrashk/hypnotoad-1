defmodule Hypnotoad.Host.SSH.Channel do

  alias Hypnotoad.Host.SSH
  use GenServer.Behaviour
  use Hypnotoad.Common
  alias Hypnotoad.Semaphore, as: S

  def start_link(conn) do
    :gen_server.start_link __MODULE__, conn, []
  end

  def execute(pid, cmd, ref) do
  	:gen_server.call(pid, {:execute, cmd, ref}, :infinity)
  end

  def upload(pid, file, content, ref) do
    :gen_server.call(pid, {:upload, file, content, ref}, :infinity)
  end

  def download(pid, file, ref) do
    :gen_server.call(pid, {:download, file, ref}, :infinity)
  end

  defrecordp :state, connection: nil, from: nil, data: "", status: 0, splitter: nil, ref: nil, channel: nil

  def init(SSH[] = ssh) do
    {:ok, state(connection: ssh)}
  end

  def handle_call({:execute, cmd, ref}, from, state(connection: SSH[user: user, _connection: conn]) = s) do
    splitter = "#{:erlang.phash2(:erlang.now)}"
    file_content = """
    echo -n #{splitter}
    #{cmd}
    """
    :gproc_ps.publish(:l, {Hypnotoad.Shell, ref}, """)
    # (( #{unless user == "root", do: "sudo"}
    #{cmd}
    # ))
    """
    S.lock({Hypnotoad.Host.SSH.Connection, conn})
    {:ok, sftp_channel} = sftp_channel(conn)
    :ok = :ssh_sftp.write_file(sftp_channel, Path.join(["/", "tmp", splitter]), file_content)
    :ssh_sftp.stop_channel(sftp_channel)
    S.unlock({Hypnotoad.Host.SSH.Connection, conn})
    S.lock({Hypnotoad.Host.SSH.Connection, conn})
    {:ok, ch} = channel(conn)
    unless user == "root" do
    	:ssh_connection.exec(conn, ch, String.to_char_list!("sudo sh -c 'sh /tmp/#{splitter} ; echo $? > /tmp/#{splitter}' ; E=`cat /tmp/#{splitter}` ; rm -f /tmp/#{splitter}; exit $E"), :infinity)
    else 
      :ssh_connection.exec(conn, ch, String.to_char_list!("sh /tmp/#{splitter} ; E=$? ; rm -f /tmp/#{splitter}; exit $E"), :infinity)
    end
  	{:noreply, state(s, from: from, splitter: splitter, ref: ref, channel: ch)}
  end

  def handle_call({:upload, file, content, ref}, _from, state(connection: SSH[_connection: conn] = ssh) = s) do
    :gproc_ps.publish(:l, {Hypnotoad.Shell, ref}, """)
    # Uploading #{file}
    """
    S.lock({Hypnotoad.Host.SSH.Connection, conn})
    {:ok, sftp_channel} = sftp_channel(conn)
    case :ssh_sftp.write_file(sftp_channel, file, content) do
      :ok ->
        :ssh_sftp.stop_channel(sftp_channel)
        S.unlock({Hypnotoad.Host.SSH.Connection, conn})
        :gproc_ps.publish(:l, {Hypnotoad.Shell, ref}, """)
        # Uploading #{file} complete
        """
        {:reply, :ok, s}
      {:error, :permission_denied} ->
        :ssh_sftp.stop_channel(sftp_channel)
        S.unlock({Hypnotoad.Host.SSH.Connection, conn})
        :gproc_ps.publish(:l, {Hypnotoad.Shell, ref}, """)
        # Uploading #{file}, permission denied, re-trying
        """
        {:ok, pid} = start_link(ssh)
        {0, home} = execute(pid, "sudo -u $SUDO_USER sh -c 'echo $HOME'", ref)
        tmp = "#{:erlang.phash2(:erlang.now)}"
        new_path = Path.join(home, ".hypnotoad.#{tmp}")
        :gproc_ps.publish(:l, {Hypnotoad.Shell, ref}, """)
        # Uploading #{file} to #{new_path} (temporarily)
        """
        S.lock({Hypnotoad.Host.SSH.Connection, conn})
        {:ok, sftp_channel} = sftp_channel(conn)
        :ok = :ssh_sftp.write_file(sftp_channel, new_path, content)
        S.unlock({Hypnotoad.Host.SSH.Connection, conn})
        :gproc_ps.publish(:l, {Hypnotoad.Shell, ref}, """)
        # Uploading #{file}, moving from #{new_path}
        """
        {:ok, pid} = start_link(ssh)
        execute(pid, "mv -f #{new_path} #{file}", ref)
        :gproc_ps.publish(:l, {Hypnotoad.Shell, ref}, """)
        # Uploading #{file} complete
        """
        {:reply, :ok, s}
    end
  end

  def handle_call({:download, file, ref}, _from, state(connection: SSH[_connection: conn]) = s) do
    :gproc_ps.publish(:l, {Hypnotoad.Shell, ref}, """)
    # Downloading #{file}
    """
    S.lock({Hypnotoad.Host.SSH.Connection, conn})
    {:ok, sftp_channel} = sftp_channel(conn)
    {:ok, data} = :ssh_sftp.read_file(sftp_channel, file)
    :ssh_sftp.stop_channel(sftp_channel)
    S.unlock({Hypnotoad.Host.SSH.Connection, conn})
    :gproc_ps.publish(:l, {Hypnotoad.Shell, ref}, """)
    # Downloading #{file} complete
    """
    {:reply, data, s}
  end

  def handle_info({:ssh_cm, _, {:data, _, _, new_data}}, state(data: data, splitter: splitter, ref: ref) = s) do
    new_data = String.split(new_data, splitter) |> Enum.reverse |> hd
    :gproc_ps.publish(:l, {Hypnotoad.Shell, ref}, new_data)
  	{:noreply, state(s, data: data <> new_data)}
  end

  def handle_info({:ssh_cm, _, {:exit_status, _, status}}, state(ref: ref) = s) do
    if status == 0 do
      :gproc_ps.publish(:l, {Hypnotoad.Shell, ref}, """)
      # EXIT CODE #{status}
      """
    else
      :gproc_ps.publish(:l, {Hypnotoad.Shell, ref}, """)
      # EXIT CODE #{status}
      """
    end
  	{:noreply, state(s, status: status)}
  end

  def handle_info({:ssh_cm, _, {:closed, _}}, state(connection: SSH[_connection: conn], channel: ch, from: from, data: data, status: status) = s) do
  	data = String.strip(data)
    :gen_server.reply(from, {status, data})
    :ssh_connection.close(conn, ch)
    S.unlock({Hypnotoad.Host.SSH.Connection, conn})
    {:stop, :normal, s}
  end

  def handle_info({:ssh_cm, _, _}, state() = s) do
  	{:noreply, s}
  end

  defp sftp_channel(conn) do
    case :ssh_sftp.start_channel(conn) do
      {:ok, sftp} -> {:ok, sftp}
      {:open_error, _, 'open failed', _} ->
        sftp_channel(conn)
    end
  end

  defp channel(conn) do
    case :ssh_connection.session_channel(conn, :infinity) do
      {:ok, ch} -> {:ok, ch}
      {:open_error, _, 'open failed', _} ->
        channel(conn)
    end
  end

end

defmodule Hypnotoad.Host.SSH.Channel.Sup do
  use Supervisor.Behaviour

  def start_link do
    :supervisor.start_link({:local, __MODULE__}, __MODULE__, [])
  end

  def init([]) do
    children = [
      worker(Hypnotoad.Host.SSH.Channel, [], restart: :transient)
    ]
    supervise(children, strategy: :simple_one_for_one)
  end
end