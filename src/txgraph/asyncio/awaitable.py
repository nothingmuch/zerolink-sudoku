import asyncio

class Volatile(object):
    """
    A bit like asyncio.Future, but set_result() can be called repeatedly,
    changing the value.
    """
    __slots__ = ('fut',)
    fut: asyncio.Future

    def __init__(self):
        # TODO there must be a simpler/more direct way to implement this
        self.fut = asyncio.get_running_loop().create_future()

    def done(self):
        return self.fut.done()

    def result(self):
        return self.fut.result()

    def set_result(self, value):
        if self.done():
            self.fut = asyncio.get_running_loop().create_future()
        self.fut.set_result(value)

    def __await__(self):
        return self.fut.__await__()

    def __hash__(self):
        return hash(id(self))

class Monotonic(Volatile):
    """
    A bit like Volatile, but the new result combines the previous and assigned
    result.
    """
    __slots__ = ('add')

    def __init__(self, zero, add):
        super().__init__()
        self.fut.set_result(zero)
        self.add = add

    def set_result(self, value):
        prev = self.result()
        join = self.add(prev, value)
        #print(prev, "+", value, "=", join)
        fut = asyncio.get_running_loop().create_future()
        fut.set_result(join)
        self.fut = fut

    def __hash__(self):
        return hash(id(self))
