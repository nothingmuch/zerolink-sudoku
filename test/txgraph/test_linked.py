import pytest
from txgraph.base import *
from txgraph.linker import *

def test_spend():
     l = Linker()

     addr = l.link_script(unlinked.Script(1, address='x', contiguous_bound_tx_id=None, fetch_oldest_tx_id=None, fetch_newest_tx_id=None, fetch_newest_tx_read_height=1))
     f = l.link_tx(unlinked.TX(1, txid='a', height=1, input_count=0, output_count=1))
     o = l.link_output(unlinked.Output(1, input_id=None, funding_tx_id=f.id, vout=0, spending_tx_id=None, vin=None, sats=1000, script_id=addr.id, height=1))

     assert o.funding_tx is f
     assert o in f.partial_outputs
     assert f.outputs == (o,)

     assert not o.has_field('spending_tx')
     assert o.height == 1

     o1 = l.link_output(unlinked.Output(1, input_id=None, funding_tx_id=f.id, vout=0, spending_tx_id=None, vin=None, sats=1000, script_id=addr.id, height=2))
     assert id(o) == id(o1)

     assert not o.has_field('spending_tx')
     assert o.height == 2

     s = l.link_tx(unlinked.TX(2, txid='b', height=2, input_count=1, output_count=1))
     o2 = l.link_output(unlinked.Output(1, input_id=1, funding_tx_id=f.id, vout=0, spending_tx_id=s.id, vin=0, sats=1000, script_id=addr.id, height=2))
     assert id(o) == id(o2)

     assert o.has_field('spending_tx')
     assert o.height == 2
     assert o.spending_tx is s
     assert o in s.partial_inputs
     assert s.inputs == (o,)

     # can't change spend height even if increasing after set (set on spending_tx)
     with pytest.raises(AttributeIdempotenceError):
         l.link_output(unlinked.Output(1, input_id=1, funding_tx_id=f.id, vout=0, spending_tx_id=s.id, vin=0, sats=1000, script_id=addr.id, height=4))


def test_spend_status_monotonicity():
     l = Linker()

     addr = l.link_script(unlinked.Script(1, address='x', contiguous_bound_tx_id=None, fetch_oldest_tx_id=None, fetch_newest_tx_id=None, fetch_newest_tx_read_height=1))
     f = l.link_tx(unlinked.TX(1, txid='a', height=1, input_count=0, output_count=1))
     s = l.link_tx(unlinked.TX(2, txid='b', height=2, input_count=1, output_count=1))
     o = l.link_output(unlinked.Output(1, input_id=1, funding_tx_id=f.id, vout=0, spending_tx_id=s.id, vin=0, sats=1000, script_id=addr.id, height=2))

     assert o.height == 2

     # can't unspend transaction
     with pytest.raises(AttributeIdempotenceError): # FIXME monotonicity?
         l.link_output(unlinked.Output(1, input_id=None, funding_tx_id=f.id, vout=0, spending_tx_id=None, vin=None, sats=1000, script_id=addr.id, height=1))
