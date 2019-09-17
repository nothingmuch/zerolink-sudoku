from dataclasses import *
import typing

import txgraph.unlinked as unlinked
import txgraph.base as base

@dataclass(repr=False)
class TX(base.MonotonicAttrs, unlinked.TX):
    """
    This transaction type extends the unlinked variant, to add relational
    fields.

    {In,out}puts are stored as tuples, but only when the {in,out}put_count is
    known. Before such time, related {in,out}puts are available in the
    partial_{in,out}puts, which should be monotonically growing sets.
    """
    __slots__ = ('inputs', 'outputs', 'partial_inputs', 'partial_outputs')
    # `...` syntax requires 3.8
    inputs: typing.Tuple#[Output, ...] - only if inputs_count is set
    outputs: typing.Tuple#[Output, ...] - only if outputs_count is set
    partial_inputs: typing.FrozenSet#[Output, ...]
    partial_outputs: typing.FrozenSet#[Output, ...]

    def __init__(self):
        self.set_slot('partial_outputs', frozenset())
        self.set_slot('partial_inputs', frozenset())

    def monotonic_set_field(self, field, value):
        if field in ('input_count', 'inputs', 'partial_inputs','output_count','outputs', 'partial_outputs', 'height'):
            # handle fields with monotonicity or triggering behaviour with individual methods
            getattr(self, 'set_' + field)(value)
        else:
            self.set_field(field, value)

    # FIXME functools.partial based wrapping?
    def set_input_count(self, count):
        self.set_io_count('input', count)

    def set_output_count(self, count):
        self.set_io_count('output', count)

    def set_io_count(self, io, count):
        """
        Sets the {in,out}put count field to the given value (must be idempotent).

        If partial_{in,out}puts is set, and its cardinality matches the count
        value, then the corresponding tuple field will also be set.
        """
        if self.has_field(io + '_count'):
            value = self.get_field(io + '_count')
            if value != count:
                print("count of ", self.id, " doesn't match", value, count)
                raise io + "count doesn't match set collection"

        self.set_field(io + '_count', count)

        if self.has_field('partial_' + io + 's'):
            # trigger verification/upgrade of partial_outputs to outputs tuple
            self.partial_outputs = frozenset()

    def set_partial_inputs(self, additional_inputs: typing.FrozenSet): # typing.FrozenSet[Output] # 3.8
        for output in additional_inputs:
            output.spending_tx = self
        self.set_io_partial('input', lambda i: i.get_field('vin'), additional_inputs)

    def set_partial_outputs(self, additional_outputs: typing.FrozenSet): # typing.FrozenSet[Output] # 3.8
        for output in additional_outputs:
            output.funding_tx = self
        self.set_io_partial('output', lambda o: o.get_field('vout'), additional_outputs)

    def set_io_partial(self, io, sort_key, additional: typing.FrozenSet): # typing.FrozenSet[Output] # 3.8
        """
        Set the partial_{in,out}puts frozenset field. The new value will be the
        union of the provided value and the previous one.

        If the corresponding count field is set and matches the cardinality of
        the union, members will be sorted by their index in order to set the
        corresponding tuple field.
        """
        if self.has_field('partial_' + io + 's'):
            union = self.get_field('partial_' + io + 's').union(additional)
        else:
            union = additional

        if self.has_field(io + '_count'):
            count = self.get_field(io + '_count')
            if len(union) > count:
                raise io + 'set size exceeds expected output count'
            if len(union) == count and not self.has_field(io + 's'):
                # all outputs are known already, so we can just set them now
                self.set_field(io + 's', tuple(sorted(union, key=sort_key)))

        self.set_field('partial_' + io + 's', union)


    def set_inputs(self, inputs: typing.Tuple):
        for input in inputs:
            input.spending_tx = self
        self.set_io_tuple('input', inputs)

    def set_outputs(self, outputs: typing.Tuple):
        for output in outputs:
            output.funding_tx = self
        self.set_io_tuple('output', outputs)

    def set_io_tuple(self, io, outputs: typing.Tuple):
        """
        Set the {in,out}puts tuple field. Must be idempotent. Implicitly sets
        the corresponding count and partial frozenset fields as well.
        """
        if self.has_field(io + 's') and outputs != self.get_field(io + 's'):
            # __setattr__ only calls set_outputs if different
            raise base.AttributeMonotonicityError(io + 's')

        self.set_field(io + 's', outputs)
        self.set_io_count(io, len(outputs))

    def set_height(self, height):
        if self.has_field('height'):
            if height != self.get_field('height'):
                raise base.AttributeIdempotenceError('height')
        else:
            self.set_field('height', height )

@dataclass(repr=False)
class Script(base.MonotonicAttrs, unlinked.Script):
    __slots__ = ('fetch_newest_tx', 'fetch_newest_tx_read_height', 'fetch_oldest_tx', 'contiguous_bound_tx')

    def __init__(self):
        pass

    def __hash__(self):
        return id(self)

    def monotonic_set_field(self, field, value):
        if field in type(self).__slots__:
            # TODO(consistency)
            # contiguous_bound_tx starts null, after which point the height field of the new values should be monotonically increasing
            # fetch_oldest starts null, gets tx value, decreases in height, and then goes null again
            # fetch_newest_tx starts null, is set to a constant value, goes null again
            self.set_field(field, value)
        else:
            self.set_field(field, value)

@dataclass(repr=False)
class Output(base.MonotonicAttrs, unlinked.Output):
    __slots__ = ('funding_tx', 'spending_tx', 'script')
    funding_tx: TX
    spending_tx: TX
    script: Script

    def __init__(self):
        pass

    def __hash__(self):
        return id(self)

    def monotonic_set_field(self, field, value):
        if field in ('funding_tx', 'spending_tx', 'height'):
            getattr(self, 'set_' + field)(value)
        else:
            self.set_field(field, value)

    def set_funding_tx(self, tx):
        """
        Associate an output with its funding transaction. Implicitly adds the
        output to the output set of that transaction.
        """
        self.set_tx('funding_tx', tx)
        self.funding_tx_id = tx.id
        tx.partial_outputs = frozenset((self,))

    def set_spending_tx(self, tx):
        """
        Associate an output with its spending transaction. Implicitly adds the
        output to the input set of that transaction.
        """
        self.set_tx('spending_tx', tx)
        self.spending_tx_id = tx.id
        tx.partial_inputs = frozenset((self,))
        self.height = tx.get_field('height')

    def set_tx(self, field, tx):
        if self.has_field(field):
            if self.get_field(field) != tx: # FIXME convert to is? we care about id(tx) here
                raise unlinked.AttributeIdempotenceError(field)

        self.set_field(field, tx)

    # FIXME bikeshed to spend_status_height?
    def set_height(self, height):
        """
        Set the known {un,}spent height of an output. Before being spent, the
        height attribute can increase in value as new esplora responses are
        added, but once a spending transaction is confirmed the height is
        fixed.
        """
        # TODO if read-at-height spending_tx should be set to None
        if self.has_field('spending_tx'):
            self.spending_tx.height = height

        if self.has_field('height'):
            if height < self.get_field('height'):
                raise base.AttributeMonotonicityError("spend status height assignments must be monotonically increasing")

        self.set_field('height', height )
