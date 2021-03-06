defmodule Hypnotoad.Plan do

  use GenServer.Behaviour
  use Hypnotoad.Common

  def start(opts) do
    :supervisor.start_child(Hypnotoad.Plan.Sup, [opts])
  end

  def start_link(opts) do
    :gen_server.start_link {:local, opts[:module]}, __MODULE__, opts, []
  end

  def module(server) do
    :gen_server.call(server, :module)
  end

  def run(server) do
    :gen_server.cast(server, :run)
  end

  defrecordp :state, module: nil, jobs: [], done_jobs: [], running?: false, failed: false, overrides: nil

  def init(opts) do
    :gproc.add_local_property(__MODULE__, Keyword.put(opts, :status, :ready))
    {:ok, state(module: opts[:module], overrides: :ets.new(__MODULE__.Overrides, [:bag]))}
  end

  def handle_call(:module, _from, state(module: module) = s) do
    {:reply, module, s}
  end

  defp prepare_overrides(host, module, args, overrides) do
    Process.put(:host, host)
    result = if module.before_filter(args) do
      Enum.each(module.requirements(args), fn({req_mod, req_args, parent}) ->
        if parent do
          {m, a} = parent
          :ets.insert(overrides, {{host, m, a}, {req_mod, req_args}})
          prepare_overrides(host, m, a, overrides) 
        end
        prepare_overrides(host, req_mod, req_args, overrides) 
      end)
      true
    else
      false
    end
    Process.delete(:host)
    result
  end

  defp start_module(host, module, args, overrides) do
    Process.put(:host, host)
    result = if module.before_filter(args) do
      reqs = Enum.map(module.requirements(args) ++ Enum.map(:ets.lookup(overrides, {host, module, args}), fn({_, {m, a}}) ->
        {m, a, nil}
      end), fn({m, a, _}) ->
        {m, a}
      end) |> Enum.uniq
      requirements = Enum.reduce(reqs, [], fn({req_mod, req_args}, acc) ->
        if start_module(host, req_mod, req_args, overrides) do
          [{req_mod, req_args}|acc]
        else
          acc
        end
      end)
      start_job(host, module, args, requirements)
      true
    else
      false
    end
    Process.delete(:host)
    result
  end

  def handle_cast(:run, state(module: module, done_jobs: done_jobs, running?: false, overrides: overrides) = s) do
    update_status(:preparing, s)
    lc {_, _, _, job} inlist done_jobs, do: Hypnotoad.Job.done(job)
    # Start jobs
    :ets.match_delete(overrides, :"_")
    Enum.each(Hypnotoad.Hosts.hosts, fn({host, _}) ->
      try do
        :gproc_ps.subscribe(:l, {Hypnotoad.Job, host, :success})
        :gproc_ps.subscribe(:l, {Hypnotoad.Job, host, :failed})
        :gproc_ps.subscribe(:l, {Hypnotoad.Job, host, :excluded})
      rescue _ ->
      end
      prepare_overrides(host, module, [], overrides)
      start_module(host, module, [], overrides)
    end)
    :gen_server.cast(self, :ready)
    {:noreply, state(s, jobs: [], done_jobs: [], running?: true, failed: nil)}
  end

  def handle_cast(:run, state() = s) do
    {:noreply, s}
  end

  def handle_cast(:ready, state(jobs: jobs) = s) do
    update_status(:running, s, start_timestamp: Hypnotoad.Utils.timestamp)
    lc {_, _, _, job} inlist jobs, do: Hypnotoad.Job.ready(job)
    {:noreply, s}
  end

  def handle_cast({:new_job, job}, state(jobs: jobs) = s) do
    {:noreply, state(s, jobs: Enum.uniq([job|jobs]))}
  end

  def handle_info({:gproc_ps_event, {Hypnotoad.Job, host, status}, {module, options}}, state(jobs: jobs, done_jobs: done_jobs, running?: true, failed: failed) = s) do
    matched_job = Enum.find(jobs, fn({host1, module1, options1, _pid}) -> host1 == host and module1 == module and options1 == options end)
    case matched_job do
      {_, _, _, pid} ->
        jobs = jobs -- [{host, module, options, pid}]
        done_jobs = [{host, module, options, pid}|done_jobs]
        cond do
          jobs == [] and status == :failed ->
            update_status(:failed, s, end_timestamp: Hypnotoad.Utils.timestamp)
          jobs == [] and failed ->
            update_status(:failed, s, end_timestamp: Hypnotoad.Utils.timestamp)
          jobs == [] ->
            update_status(:done, s, end_timestamp: Hypnotoad.Utils.timestamp)
          true ->
            :ok
        end
        {:noreply, state(s, jobs: jobs, done_jobs: done_jobs, running?: jobs != [], failed: failed || (status == :failed))}
      nil ->
        L.error "Job ${module} ${options} on host ${host} reported status ${status} but was not in the list of pending jobs, in the done jobs: ${done?}",
                module: module, options: options, status: status, host: host, done?: Enum.any?(done_jobs, fn({host1, module1, options1, _pid}) -> host1 == host and module1 == module and options1 == options end)
        {:noreply, s}
    end 
  end

  def handle_info({:"DOWN", _ref, _type, pid, info}, state(jobs: jobs, running?: true) = s) do
    case Enum.find(jobs, fn({_, _, _, pid1}) -> pid1 == pid end) do
      {host, module, options, _pid} ->
        L.error "Job ${module} ${options} at host ${host} exited with ${info}", module: module, options: options, host: host, info: info
      _ ->
        :ok # we already wiped jobs out
    end        
    {:noreply, s}
  end

  def handle_info(_, state() = s) do
    {:noreply, s}
  end

  defp update_status(type, state(module: module), extra // []) do
    props = :gproc.lookup_local_properties(__MODULE__)
    start_timestamp = props[self][:start_timestamp]
    :gproc.unreg({:p,:l, __MODULE__})
    :gproc.add_local_property(__MODULE__, Keyword.merge([module: module, status: type, start_timestamp: start_timestamp], extra))
    :gproc_ps.publish(:l, Hypnotoad.Plan, self)
  end

  defp start_job(host, module, options, reqs) do
    {:ok, pid} = Hypnotoad.Job.start(host: host, module: module, requirements: reqs, options: options, plan: self)
    Process.monitor(pid)
    :gen_server.cast(self, {:new_job, {host, module, options, pid}})
  end

end

defmodule Hypnotoad.Plan.Sup do
  use Supervisor.Behaviour

  def start_link do
    :supervisor.start_link({:local, __MODULE__}, __MODULE__, [])
  end

  def init([]) do
    children = [
      worker(Hypnotoad.Plan, [], restart: :transient)
    ]
    supervise(children, strategy: :simple_one_for_one)
  end
end