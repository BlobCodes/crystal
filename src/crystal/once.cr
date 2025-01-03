# This file defines the functions `__crystal_once_init` and `__crystal_once` expected
# by the compiler. `__crystal_once` is called each time a constant or class variable
# has to be initialized and is its responsibility to verify the initializer is executed
# only once. `__crystal_once_init` is executed only once at the beginning of the program
# and the result is passed on each call to `__crystal_once`.

module Crystal
  # :nodoc:
  struct OnceWaiter
    property fiber : Fiber
    property next_entry : OnceWaiter*

    def initialize(@fiber, @next_entry)
    end
  end

  # :nodoc:
  struct OnceOp
    include PointerLinkedList::Node

    property waiting : OnceWaiter* = Pointer(OnceWaiter).null
    property flag : Bool*

    def initialize(@flag)
    end
  end

  @@once_ops = uninitialized PointerLinkedList(OnceOp)
  @@once_lock = uninitialized Crystal::SpinLock

  # :nodoc:
  class_property once_ops
  # :nodoc:
  class_property once_lock
end

# :nodoc:
#
# Should codegen to the following LLVM IR (before being inlined):
# ```
# define void @"*__crystal_once_unreachable:NoReturn"() local_unnamed_addr {
# entry:
#   unreachable
# }
# ```
#
# Can be used like `@llvm.assume(i1 cond)` as `unreachable unless (assumption)`.
# The behaviour of the program is undefined if the assumption is broken.
#
# TODO: Maybe this could be in `Intrinsics`?
@[AlwaysInline]
def __crystal_once_unreachable : NoReturn
  x = uninitialized NoReturn
  x
end

# :nodoc:
# This method is supposed to initialize and return the state variable used for `__crystal_once`,
# but using the `Crystal::ONCE_MUTEX` variable in combination with the @[AlwaysInline] annotation
# on `__crystal_once` allows LLVM to defer loading the once mutex to when we actually need it.
#
# Since we only need the once mutex on the first access of any const variable,
# but don't need it all the other times, this reduces the register pressure when accessing a const.
fun __crystal_once_init : Void*
  Crystal.once_lock = Crystal::SpinLock.new
  Crystal.once_ops = Crystal::PointerLinkedList(Crystal::OnceOp).new

  Pointer(Void).null
end

# :nodoc:
# Simply defers to `__crystal_once_exec` in the rare case we need to initialize a variable.
#
# Using `@[AlwaysInline]` allows LLVM to optimize const accesses.
# TODO: Since this is an inlined `fun`, the symbol will be exposed but never be referenced.
@[AlwaysInline]
fun __crystal_once(_state : Void*, flag : Bool*, initializer : Void*) : Void
  return if flag.value
  __crystal_once_exec(flag, initializer)

  # Lets LLVM assume that it must not call `once` anymore for this global
  __crystal_once_unreachable unless flag.value
end

# :nodoc:
# Using @[NoInline] doesn't improve performance but instead reduces
# binary size since LLVM would otherwise inline this everywhere.
#
# Using the cold calling convention limits the amount of stack push/pop
# operations on the call site, reducing binary size.
@[NoInline]
@[CallConvention("Cold")]
fun __crystal_once_exec(flag : Bool*, initializer : Void*) : Void
  this_op = uninitialized Crystal::OnceOp

  Crystal.once_lock.lock
  begin
    Atomic::Ops.fence(:acquire, singlethread: false)
    return if flag.value

    Crystal.once_ops.each do |op|
      next unless op.value.flag == flag

      # global is already being initialized
      # check for recursion
      current_waiting = op.value.waiting
      this_fiber = Fiber.current
      until current_waiting.null?
        if this_fiber == current_waiting.value.fiber
          Atomic::Ops.fence(:release, singlethread: false)
          Crystal.once_lock.unlock

          raise "Recursion while initializing class variables and/or constants"
        end
        current_waiting = current_waiting.value.next_entry
      end

      # no recursion detected
      # wait for the initializing fiber to complete
      waiter = Crystal::OnceWaiter.new(Fiber.current, op.value.waiting)
      op.value.waiting = pointerof(waiter)

      Atomic::Ops.fence(:release, singlethread: false)
      Crystal.once_lock.unlock
      Fiber.suspend
      return
    end

    # This variable is not yet being initialized
    this_op = Crystal::OnceOp.new(flag)
    Crystal.once_ops.push(pointerof(this_op))
    Atomic::Ops.fence(:release, singlethread: false)
    Crystal.once_lock.unlock
  end

  Proc(Nil).new(initializer, Pointer(Void).null).call

  # Mark this variable as initialized
  Crystal.once_lock.sync do
    Atomic::Ops.fence(:acquire, singlethread: false)
    flag.value = true
    Crystal.once_ops.delete(pointerof(this_op))
    Atomic::Ops.fence(:release, singlethread: false)
  end

  # Unlock other fibers depending on this specific variable
  current_waiting = this_op.waiting
  while current_waiting
    # We have to load this as volatile since the data structure in the
    # foreign fiber's stack we depend on may be cleared once it is resumed.
    waiting = uninitialized Crystal::OnceWaiter
    Intrinsics.memcpy(pointerof(waiting), current_waiting, sizeof(Crystal::OnceWaiter), is_volatile: true)
    waiting.fiber.enqueue
    current_waiting = waiting.next_entry
  end
end
