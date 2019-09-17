from dataclasses import *
import typing

import txgraph.base as base

#TODO can frozen=True?
@dataclass(repr=False) # disabled because of recursion with subclasses' fields, which aren't necessarily plain values.
class TX(base.IdempotentAttrs):
    """
    This class represents a single transaction row in the relational model
    (without inputs/outputs rows).
    """
    __slots__ = ('id', 'txid', 'height', 'input_count', 'output_count') # truly immutable? (named tuple class?)
    id: int
    txid: str
    height: int
    input_count: int
    output_count: int

    # FIXME async
    # def inputs_are_known(self):
    #     return self.has_field('input_count')

    # def outputs_are_known(self):
    #     return self.has_field(field,'output_count')

@dataclass(repr=False)
class Output(base.IdempotentAttrs):
    """
    This class represents an output row optionall joined with its spending input row.
    """
    __slots__ = ('id', 'funding_tx_id', 'vout', 'script_id', 'sats', 'input_id', 'spending_tx_id', 'vin', 'height')
    id: int
    funding_tx_id: int
    vout: int
    script_id: int
    sats: int
    input_id: int
    spending_tx_id: int
    vin: int

    # FIXME async
    # @property
    # def outpoint(self):
    #     return self.get_field('funding_tx').get_field('txid') + ':' + str(self.get_field('vout'))

    # @property
    # def inpoint(self):
    #     return self.get_field('spending_tx').get_field('txid') + ':' + str(self.get_field('vin'))

    # @property
    # def is_spent(self):
    #     return not self.spending_tx_id is None

@dataclass(repr=False)
class Script(base.IdempotentAttrs):
    """
    This class represents a script used in an output, along with metadata about
    how much is known about the set of transactions associated with that
    address as of some block height.
    """
    __slots__ = ('id', 'address', 'contiguous_bound_tx_id', 'fetch_newest_tx_id', 'fetch_newest_tx_read_height', 'fetch_oldest_tx_id')
    id: int
    address: str
    contiguous_bound_tx_id: int
    fetch_newest_tx_id: int
    fetch_newest_tx_read_height: int
    fetch_oldest_tx_id: int
