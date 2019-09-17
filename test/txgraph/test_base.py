import pytest
from dataclasses import *
from txgraph.base import *

@dataclass
class Foo(IdempotentAttrs):
    __slots__ = ('a', 'b')
    a: str
    b: int

    def __init__(self):
        pass


def test_slot_based_fields():
    x = Foo()

    assert not x.has_slot('a')
    assert not x.has_field('a')

    with pytest.raises(AttributeError):
        x.get_slot('a')
    with pytest.raises(AttributeError):
        x.get_field('a')
    with pytest.raises(AttributeError):
        x.a

    x.a = 'foo'
    assert x.has_slot('a')
    assert x.has_field('a')
    assert x.get_slot('a') == 'foo'
    assert x.get_field('a') == 'foo'
    assert x.a == 'foo'

def test_idempotence():
    x = Foo()

    assert not x.has_slot('a')

    x.a = 'foo'

    assert x.a == 'foo'

    x.a = 'foo'
    assert x.a == 'foo'

    with pytest.raises(AttributeIdempotenceError):
        x.a = 'bar'

def test_subscripting():
    """check for sqlite.Row like subscripting behaviour"""
    x = Foo()

    assert len(x) == 2

    assert 'a' not in x

    with pytest.raises(KeyError):
        x['a']

    x['a'] = 'foo'
    assert x['a'] == 'foo'
    assert 'a' in x

    assert x['A'] == 'foo'

    with pytest.raises(KeyError):
        x['BadKey'] = 7

    with pytest.raises(AttributeError): # FIXME is this the right error?
        x.astuple()

    x.b = 42
    assert x.astuple() == ('foo', 42)
    assert x.asdict() == { 'a': 'foo', 'b': 42 }

def test_absorb():
    x = Foo()
    y = Foo()
    z = Foo()
    y.a = 'foo'
    z.b = 42

    x.absorb_fields(y)
    x.absorb_fields(z)

    assert x.astuple() == ('foo', 42)

def test_absorb_idempotent():
    x = Foo()
    y = Foo()
    z = Foo()
    y.a = 'foo'
    z.a = 'foo'
    z.b = 42

    x.absorb_fields(y)
    x.absorb_fields(z)

    assert x.astuple() == ('foo', 42)

def test_absorb_conflict():
    x = Foo()
    y = Foo()
    z = Foo()
    y.a = 'foo'
    z.a = 'bar'
    z.b = 42

    x.absorb_fields(y)

    with pytest.raises(AttributeIdempotenceError):
        x.absorb_fields(z)

@dataclass
class NumberGoUp(MonotonicAttrs):
    __slots__ = ('a')
    a: int

    # FIXME this API kind of sucks... predicate?
    def monotonic_set_field(self, field, value):
        if self.has_field(field) and self.get_field(field) > value:
            raise AttributeMonotonicityError(field)
        self.set_field(field, value)

def test_monotone():
    x = NumberGoUp(3)
    assert x.a == 3
    x.a = 4
    assert x.a == 4
    x.a = 4
    assert x.a == 4
    x.a = 5
    assert x.a == 5
    with pytest.raises(AttributeMonotonicityError):
        x.a = 4
