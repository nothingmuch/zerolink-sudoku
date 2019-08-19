import txgraph.linked as linked
import txgraph.asyncio.base as base
import txgraph.asyncio.awaitable as awaitable

class TX(base.AsyncAttr, linked.TX):
    """
    Linked transaction object with awaitable attributes.
    """
    __slots__ = ('linker',)

    # note that AsyncAttr.__init__ is used, not linker.TX.__init__

    def create_awaitable(self, field):
        if field in ('partial_inputs', 'partial_outputs'):
            return awaitable.Monotonic(frozenset(), lambda a, b: a.union(b))
        else:
            return super().create_awaitable(field)

    async def load_field(self, field):
        if field in ('height', 'txid', 'input_count', 'output_count'):
            await self.linker.load_tx_fields(self.id, field)
        if field in ('partial_outputs', 'outputs'):
            await self.linker.load_tx_outputs(self.id, field)
        if field in ('partial_inputs', 'inputs'):
            await self.linker.load_tx_inputs(self.id, field)

    def __hash__(self):
        return hash(self.id)

class Script(base.AsyncAttr, linked.Script):
    __slots__ = ('linker',)

    def create_awaitable(self, field):
        if field in ('contiguous_bound_tx', 'contiguous_bound_tx_id', 'fetch_newest_tx_id', 'fetch_newest_tx',
                     'fetch_newest_tx_read_height', 'fetch_oldest_tx_id', 'fetch_oldest_tx'):
            return awaitable.Volatile()
        else:
            return super().create_awaitable(field)

    async def load_field(self, field):
        await self.linker.load_script_fields(self.id, field)

    def __hash__(self):
        return hash(self.id)

class Output(base.AsyncAttr, linked.Output):
    __slots__ = ('linker',)

    # TODO def equivalent_outputs - async iterator returns all outputs with same script_id?


    def create_awaitable(self, field):
        if field in ('height'):
            # TODO(bikeshedding) rename to spend_status_height

            # 0 should really be self.funding_tx.height, but we don't want to
            # block here and it might not be known secondly, this should
            # arguably raise an exception if b < a, since values observed from
            # esplora should also be monotonicly increasing.
            return awaitable.Monotonic(0, lambda a, b: max(a, b))
        else:
            return super().create_awaitable(field)

    async def load_field(self, field):
        # TODO this code could avoid awaiting on own foreign key field by selecting
        # based output.id field and joining. get_spending_tx_of(output_id) ?
        if field == 'spending_tx':
            # TODO(read-at-height) this future can wait a long time (if
            # currently unspent). with read-at-height it can instead be
            # fulfilled with None.
            self.set_field(field, self.linker.get_tx(await self.spending_tx_id))
        if field == 'funding_tx':
            self.set_field(field, self.linker.get_tx(await self.funding_tx_id))
        if field == 'script':
            self.set_field(field, self.linker.get_script(await self.script_id))
        else:
            await self.linker.load_output_fields(self.id, field)

    def __hash__(self):
        return hash(self.id)

    # # FIXME async property? return a future
    # @property
    # def outpoint(self):
    #     tx = await self.funding_tx
    #     f.set_result(await tx.txid + ':' + await self.vout)

    # @property
    # async def inpoint(self):
    #     tx = await self.spending_tx
    #     return await tx.txid + ':' + await self.vin

    # @property
    # async async def is_spent(self): # FIXME take block height as param?
    #     # FIXME(async) volatile
    #     #await self.spending_tx_id
    #     return self.has_field('spending_tx_id')
