import asyncio
import txgraph.base as base
import dataclasses

class AsyncAttr(base.MonotonicAttrs):
    """
    Base class for graph objects whose attributes are awaitable.
    Fields are considered set once awaitable.done() is true.

    Overrides {get,has,set}_field to implement this additional awaitable
    indirection (this is *not* a behavioural sub-type of MonotonicAttrs).

    The default awaitable is a future, but awaitable.Volatile is supported for
    attributes that allow inconsistent or monotonic reads.
    """
    # __slots__ = ('linker',) # must be declared in subclasses
    __slots__ = ()

    def __init__(self, linker):
        self.set_slot('linker', linker)

    def __getattr__(self, field):
        """
        When no attribute value is set, in addition to setting up
        an awaitable to hold the value, create a task which loads
        the value using the linker.
        """
        if field in ('id', 'linker') or field not in self.all_mro_slots():
            return self.get_slot(field)

        return self.create_load_field_task(field)

    def create_load_field_task(self, field):
        """
        Spawns a task (kept in the linker) that provides a result for the
        futures.

        This should only be called once per field from __getattr_.
        """
        # TODO for idempotent attrs just store the task directly and error if set_result is different
        # how to get value back from other attribute sets?

        # need to create a future here, because set_result will be called as
        # part of the load task
        fut = self.get_or_create_awaitable(field)

        # TODO delegate task management/creation to linker?
        # this seems like the way to go from an error handling point of view,
        # the linker should have a coroutine managing this
        task = asyncio.create_task(self.load_field(field))

        # kind of a hack to avoid tasks being garbage collected
        # just add add_done_callback to future that captures the task?
        self.linker.tasks.add(task)
        task.add_done_callback(lambda task: self.linker.tasks.remove(task)) # TODO check .result(), check for error

        return fut

    def has_field(self, field):
        """
        Returns .done() on the awaitable slot value if one is set, otherwise
        returns false.
        """

        # avoid calling super().has_field() due to infinite recursion through
        # __getattr__. instead
        # FIXME is has_slot broken on these classes?
        try:
            return self.get_slot(field).done()
        except AttributeError:
            return False

    def get_field(self, field):
        """
        Returns .result() on the awaitable slot value. Effectively a non
        blocking read (will error if no value is set yet).
        """
        return self.get_slot(field).result() # TODO catch & rethrow as AttributeError?

    def get_or_create_awaitable(self, field):
        """
        Create a future for use in the attribute slot.

        Overridden to create other awaitable types.
        """
        try:
            return self.get_slot(field)
        except AttributeError:
            fut = self.create_awaitable(field)
            self.set_slot(field, fut)
            return fut

    def create_awaitable(self, field):
        """
        The default awaitable kind is a future, but this can be overridden
        to provide awaitable.Volatile.
        """
        return asyncio.get_running_loop().create_future()

    def set_field(self, field, value):
        """
        Calls .set_result() on the awaitable slot value, creating it if
        necessary.
        """
        if field in ('id', 'linker') or field not in self.all_mro_slots():
            self.set_slot(field, value)
        else:
            fut = self.get_or_create_awaitable(field)
            if fut.done():
                if id(fut.result()) != id(value) and fut.result() != value:
                    # TODO wrap errors from vanilla futures?
                    fut.set_result(value)
                return
            fut.set_result(value)

    def asdict(self):
        return {k: self.get_field(k) for k in filter(self.has_field, map(lambda f: f.name, dataclasses.fields(self)))}
