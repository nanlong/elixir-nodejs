defmodule NodeJS.Test do
  use ExUnit.Case, async: true
  doctest NodeJS

  setup do
    path =
      __ENV__.file
      |> Path.dirname()
      |> Path.join("js")

    start_supervised({NodeJS.Supervisor, path: path})

    :ok
  end

  defp js_error_message(msg) do
    msg
    |> String.split("\n")
    |> case do
      [_head, js_error | _tail] -> js_error
    end
    |> String.trim()
  end

  describe "large payload" do
    test "does not explode" do
      NodeJS.call!({"keyed-functions", "getBytes"}, [128_000])
    end
  end

  describe "calling default-function-echo" do
    test "returns first arg" do
      assert 1 == NodeJS.call!("default-function-echo", [1])
      assert "two" == NodeJS.call!("default-function-echo", ["two"])
      assert %{"three" => 3} == NodeJS.call!("default-function-echo", [%{three: 3}])
      assert nil == NodeJS.call!("default-function-echo")
      assert 5 == NodeJS.call!({"default-function-echo"}, [5])
    end
  end

  describe "calling keyed-functions hello" do
    test "replies" do
      assert "Hello, Joel!" == NodeJS.call!({"keyed-functions", "hello"}, ["Joel"])
    end
  end

  describe "calling keyed-functions math.add and math.sub" do
    test "returns correct values" do
      assert 2 == NodeJS.call!({"keyed-functions", "math", "add"}, [1, 1])
      assert 1 == NodeJS.call!({"keyed-functions", "math", "sub"}, [2, 1])
      assert 2 == NodeJS.call!({"keyed-functions", :math, :add}, [1, 1])
      assert 1 == NodeJS.call!({"keyed-functions", :math, :sub}, [2, 1])
    end
  end

  describe "calling keyed-functions throwTypeError" do
    test "returns TypeError" do
      assert {:error, msg} = NodeJS.call({"keyed-functions", :throwTypeError})
      assert js_error_message(msg) === "TypeError: oops"
    end

    test "with call! raises error" do
      assert_raise NodeJS.Error, fn ->
        NodeJS.call!({"keyed-functions", :oops})
      end
    end
  end

  describe "calling keyed-functions getIncompatibleReturnValue" do
    test "returns a JSON.stringify error" do
      assert {:error, msg} = NodeJS.call({"keyed-functions", :getIncompatibleReturnValue})
      assert msg =~ "Converting circular structure to JSON"
    end
  end

  describe "calling things that are not functions: " do
    test "module does not exist" do
      assert {:error, msg} = NodeJS.call("idontexist")
      assert msg =~ "Error: Cannot find module 'idontexist'"
    end

    test "function does not exist" do
      assert {:error, msg} = NodeJS.call({"keyed-functions", :idontexist})
      assert js_error_message(msg) === "TypeError: fn is not a function"
    end

    test "object does not exist" do
      assert {:error, msg} = NodeJS.call({"keyed-functions", :idontexist, :foo})
      assert js_error_message(msg) === "TypeError: Cannot read property 'foo' of undefined"
    end
  end

  describe "calling function re-exported from an NPM dependency" do
    test "uuid" do
      assert {:ok, _uuid} = NodeJS.call({"keyed-functions", :uuid})
    end
  end

  describe "calling a function in a subdirectory index.js" do
    test "subdirectory" do
      assert {:ok, true} = NodeJS.call("subdirectory")
    end
  end

  describe "calling functions that return promises" do
    test "gets resolved value" do
      assert {:ok, 1234} = NodeJS.call("slow-async-echo", [1234])
    end

    test "doesn't cause responses to be delivered out of order" do
      task1 =
        Task.async(fn ->
          NodeJS.call("slow-async-echo", [1111])
        end)

      task2 =
        Task.async(fn ->
          NodeJS.call("default-function-echo", [2222])
        end)

      assert {:ok, 2222} = Task.await(task2)
      assert {:ok, 1111} = Task.await(task1)
    end
  end

  describe "overriding call timeout" do
    test "works, and you can tell because the slow function will time out" do
      assert {:error, "Call timed out."} = NodeJS.call("slow-async-echo", [1111], timeout: 0)
      assert_raise NodeJS.Error, fn -> NodeJS.call!("slow-async-echo", [1111], timeout: 0) end
      assert {:ok, 1111} = NodeJS.call("slow-async-echo", [1111])
    end
  end

  describe "strange characters" do
    test "are transferred properly between js and elixir" do
      assert {:ok, "’"} = NodeJS.call("default-function-echo", ["’"], binary: true)
    end
  end

  describe "Implementation details shouldn't leak:" do
    test "Timeouts do not send stray messages to calling process" do
      assert {:error, "Call timed out."} = NodeJS.call("slow-async-echo", [1111], timeout: 0)

      refute_receive {_ref, {:error, "Call timed out."}}, 50
    end

    test "Crashes do not bring down the calling process" do
      own_pid = self()

      Task.async(fn ->
        {:error, _err} = NodeJS.call("slow-async-echo", [1111])
        # Make sure we reach this line
        Process.send(own_pid, :received_error, [])
      end)

      # Abuse internal APIs / implementation details to find and kill the worker process.
      # Since we don't know which is which, we just kill them all.
      [{_, child_pid, _, _} | _rest] = Supervisor.which_children(NodeJS.Supervisor)
      workers = GenServer.call(child_pid, :get_all_workers)

      Enum.each(workers, fn {_, worker_pid, _, _} ->
        Process.exit(worker_pid, :kill)
      end)

      assert_receive :received_error, 50
    end
  end
end
