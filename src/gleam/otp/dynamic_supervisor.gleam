import gleam/dict.{type Dict}
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor.{type StartError}
import gleam/otp/intensity_tracker.{type IntensityTracker}
import gleam/result
import gleam/string

pub opaque type Message(argument, children_message, id) {
  ChildAdded(child: ChildSpec(children_message, argument))
  ChildRemoved(id: id)
  Exit(process.ExitMessage)
  RetryRestart(Pid)
}

type State(msg, argument, id) {
  State(
    restarts: IntensityTracker,
    retry_restarts: Subject(Pid),
    registry: ChildrenRegistry(msg, argument, id),
  )
}

type ChildrenRegistry(msg, argument, id) {
  ChildrenRegistry(
    processes: Dict(id, Pid),
    children: Dict(Pid, Child(msg, argument, id)),
  )
}

pub type Spec(argument) {
  Spec(
    argument: argument,
    max_frequency: Int,
    frequency_period: Int,
    init: fn(argument) -> Nil,
  )
}

pub opaque type ChildSpec(msg, argument) {
  ChildSpec(
    start: fn(argument) -> Result(Subject(msg), StartError),
    finalize: fn(argument, Subject(msg)) -> Nil,
  )
}

type Child(msg, argument, id) {
  Child(spec: ChildSpec(msg, argument), id: id)
}

fn loop(
  message: Message(argument, children_message, id),
  state: State(msg, argument, id),
) -> actor.Next(
  Message(argument, children_message, id),
  State(msg, argument, id),
) {
  case message {
    Exit(exit_message) -> handle_exit(exit_message.pid, state)
    RetryRestart(pid) -> handle_exit(pid, state)
    ChildAdded(child) -> todo
    ChildRemoved(id) -> handle_child_removed(state, id)
  }
}

fn handle_child_removed(
  state: State(msg, argument, id),
  id: id,
) -> actor.Next(Message(a, b, id), State(msg, argument, id)) {
  case dict.get(state.registry.processes, id) {
    Error(_) -> actor.continue(state)
    Ok(pid) -> {
      dict.delete(state.registry.processes, id)
      dict.delete(state.registry.children, pid)
      process.kill(pid)
      actor.continue(state)
    }
  }
}

fn init(
  spec: Spec(argument),
) -> actor.InitResult(
  State(msg, argument, id),
  Message(argument, children_message, id),
) {
  // Create a subject so that we can asynchronously retry restarting when we
  // fail to bring an exited child
  let retry = process.new_subject()

  // Trap exits so that we get a message when a child crashes
  process.trap_exits(True)

  // Combine selectors
  let selector =
    process.new_selector()
    |> process.selecting(retry, RetryRestart)
    |> process.selecting_trapped_exits(Exit)

  todo
}

type HandleExitError {
  RestartFailed(pid: Pid, restarts: IntensityTracker)
  TooManyRestarts
  ChildNotFound
}

pub fn worker(
  start: fn(argument) -> Result(Subject(msg), StartError),
  finalize: fn(argument, Subject(msg)) -> Nil,
) -> ChildSpec(msg, argument) {
  ChildSpec(start: start, finalize: finalize)
}

fn handle_exit(
  pid: Pid,
  state: State(msg, argument, id),
) -> actor.Next(
  Message(argument, children_message, id),
  State(msg, argument, id),
) {
  // Check to see if there has been too many restarts in this period
  let outcome = {
    use restarts <- result.then(
      state.restarts
      |> intensity_tracker.add_event
      |> result.map_error(fn(_) { TooManyRestarts }),
    )
    use child <- result.try(
      dict.get(state.registry.children, pid)
      |> result.map_error(fn(_) { ChildNotFound }),
    )
    Ok(child)
  }
  case outcome {
    Ok(_) -> todo
    Error(TooManyRestarts) ->
      actor.Stop(process.Abnormal(
        "Child processes restarted too many times within allowed period",
      ))
    Error(RestartFailed(failed_child, restarts)) -> {
      // Asynchronously enqueue the restarting of this child again as we were
      // unable to restart them this time. We do this asynchronously as we want
      // to have a chance to handle any system messages that have come in.
      process.send(state.retry_restarts, failed_child)
      let state = State(..state, restarts: restarts)
      actor.continue(state)
    }
    Error(ChildNotFound) ->
      // Child not found means it was evicted by the user,
      // so we should not be restarting it, nothing to do
      actor.continue(state)
  }
}

fn start_and_set_child(
  spec: ChildSpec(msg, argument),
  id: id,
) -> Result(Pid, Nil) {
  todo
}

// TODO: more sophsiticated stopping of processes. i.e. give supervisors
// more time to shut down.
fn shutdown_child(pid: Pid, _spec: ChildSpec(msg, argument)) -> Nil {
  process.send_exit(pid)
}
