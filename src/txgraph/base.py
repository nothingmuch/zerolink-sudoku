# Base classes for different kinds of model objects (unlinked, linked, and
# async linked)

from dataclasses import *
import itertools

class AttributeIdempotenceError(AttributeError):
    pass

class AttributeMonotonicityError(AttributeError):
    pass

@dataclass(repr=False)
class IdempotentAttrs(object):
    """
    A base class for objects whose attributes can be set repeatedly, so long as
    it's always to the same value.

    Such attributes are referred to as "fields", and in this implementation
    fields correspond directly to the slots of the instance
    """

    __slots__ = ()

    def __setattr__(self, field, value):
        """
        If assigning an attr that is already set, check that the value is the
        same or throw an error.
        """

        if self.has_field(field):
            prev = self.get_field(field)
            if prev == value:
                return
            else:
                raise AttributeIdempotenceError(field)

        self.set_field(field, value)

    def absorb_fields(self, proto):
        """
        For every field defined in the invocant object, set it to the
        corresponding value in the argument object argument if it has one.
        """
        for field in self.all_mro_slots(): # TODO dataclasses fields?
            if proto.has_field(field):
                value = proto.get_field(field)
                if value is not None: # or slot in ('spending_tx_id', 'vin'): # TODO when result is >= read height
                    # note that this calls __setattr__ and not set_field in order to
                    # trigger validation if implemented
                    self.__setattr__(field, value)

    def has_slot(self, slot):
        return hasattr(self, slot)

    def get_slot(self, slot):
        return object.__getattribute__(self, slot)

    def set_slot(self, slot, value):
        object.__setattr__(self, slot, value)

    # subclasses override these
    has_field = has_slot
    get_field = get_slot
    set_field = set_slot

    def asdict(self):
        return asdict(self)

    def astuple(self):
        return astuple(self)

    def __dict__(self):
        return dict(self)

    def __iter__(self):
        return iter(self.all_mro_slots())

    def __len__(self):
        return len(self.all_mro_slots())

    # case insensitive, like sqlite.Row
    def __contains__(self, field):
        return self.has_field(field.lower())

    def __getitem__(self, field):
        try:
            return self.get_field(field.lower())
        except AttributeError as e:
            raise KeyError(e)

    def __setitem__(self, field, value):
        try:
            return self.set_field(field.lower(), value)
        except AttributeError as e:
            raise KeyError(e)

    # FIXME remove. this is hacky and should really be redone by subclassing.
    def all_mro_slots(self):
        """
        Produces (and caches) the union of all __slots__ defined in an object's
        inheritence hierarchy.
        """
        if hasattr(type(self), '__all_mro_slots__'):
            return type(self).__all_mro_slots__

        def get_slots(c):
            if hasattr(c, '__slots__'):
                return c.__slots__
            else:
                return ()

        slot_groups = map(get_slots, reversed(type(self).mro()))
        combined_slots = frozenset(itertools.chain.from_iterable(slot_groups))
        type(self).__all_mro_slots__ = combined_slots # FIXME cache by type instead of caching in type - only usage left is absorb_fields
        return combined_slots

@dataclass(repr=False)
class MonotonicAttrs(IdempotentAttrs): # TODO rename to StateMachineAttr? script metadata fields are not actually monotone
    """
    A base class for objects whose fields can be set repeatedly, with the
    actual value set being the least upper bound of the previous value and the
    new value.

    The actual implementation needs to be provided by monotonic_set_field in
    the concrete subclass.
    """
    __slots__ = ()

    # FIXME this is a shitty API, need set_initial_value and update_value based API
    def __setattr__(self, field, value):
        if value is None:
            raise('no') # TODO 
        if self.has_field(field):
            prev = self.get_field(field)
            if id(prev) == id(value) or prev == value:
                return # no information gained

        self.monotonic_set_field(field, value)
