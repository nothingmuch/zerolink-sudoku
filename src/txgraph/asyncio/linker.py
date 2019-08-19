import collections
import asyncio

import txgraph.linker as idempotent
import txgraph.esplora as esplora
import txgraph.asyncio.linked as async_linked

# TODO @attr.s
class Linker(idempotent.Linker):
    """
    Graph linker that provides an async API, for a lazy-(down-)loaded virtual
    graph.

    All graph objects contain a circular reference linker for loading their
    fields.

    Graph objects' __getattr__ method (inherited from AsyncAttr) will create
    asyncio.Tasks on demand in to populate the field data. Fields are first
    loaded from the sparse database, falling back to downloading the data if
    still missing.

    The {has,get}_field methods provide a non blocking, non-async way to read
    the current field values.
    """

    # TODO - tx->outputs->spending->txs->outputs->addresses etc - generate join selects w/ only final column group, w/ set operations like insersect, union etc

    def __init__(self, db, client, TX=async_linked.TX, Script=async_linked.Script, Output=async_linked.Output):
        self.db = db
        self.client = client
        self.txs = collections.defaultdict(lambda: TX(self))
        self.scripts = collections.defaultdict(lambda: Script(self))
        self.outputs = collections.defaultdict(lambda: Output(self))
        self.tasks = set()
        self.requests = {}

    async def download(self, path):
        """
        Query the upstream API using the client, and save the results in the
        database. Only a single task is created for duplicate requests. Returns
        the response ID.
        """
        if path not in self.requests:
            self.requests[path] = asyncio.create_task(self.send_request(path))
        return await self.requests[path]

    async def send_request(self, path):
        """
        Send arbitrary GET requests prefixed by the base attribute.
        """
        response = await self.client.get(path)
        return self.db.insert_response(path, response)

    async def download_blocks_tip(self):
        return await self.download(esplora.API.blocks_tip())

    async def load_tx_by_txid(self, txid):
        """
        This can be used when no internal ID is available yet for a transaction
        of interest.
        """
        unlinked = self.db.load_tx_by_txid(txid)

        if unlinked is None:
            await self.download(esplora.API.tx(txid))
            unlinked = self.db.load_tx_by_txid(txid)

        return self.link_tx(unlinked)


    async def load_tx_fields(self, tx_id, field):
        """
        Loads from the DB or downloads the fields associated with a specific
        row ID.

        Assumes txid (and height) is already set, but information about related
        inputs and outputs might be downloaded.
        """
        # field was not in memory
        tx = self.link_tx(self.db.load_tx_fields(tx_id)) # FIXME create futures for all related fields?

        # check if the db had the data we needed
        if tx.has_field(field):
            return

        await self.download(esplora.API.tx(await tx.txid))
        self.link_tx(self.db.load_tx_fields(tx_id))

    async def load_tx_outputs(self, tx_id, field):
        """
        Loads outputs of a given a funding transaction ID. The transaction is
        implicitly downloaded by waiting on its output_count field.
        """
        await self.load_tx_fields(tx_id, 'output_count')
        tx = self.get_tx(tx_id)

        if not tx.has_field('output_count'):
            await self.download(esplora.API.tx(await tx.txid))
            self.link_tx(self.db.load_tx_fields(tx_id))

        output_count = tx.get_field('output_count')

        unlinked = self.db.load_tx_outputs(tx_id)
        outputs = tuple((map(self.link_output, unlinked)))
        if len(outputs) == output_count:
            tx.outputs = outputs
        else:
            tx.partial_outputs = frozenset(outputs)

    async def load_tx_inputs(self, tx_id, field):
        """
        Loads outputs (inputs of) a given a spending transaction ID. The
        transaction is implicitly downloaded by waiting on its input_count
        field.
        """
        await self.load_tx_fields(tx_id, 'input_count')
        tx = self.get_tx(tx_id)

        if not tx.has_field('input_count'):
            await self.download(esplora.API.tx(await tx.txid))
            self.link_tx(self.db.load_tx_fields(tx_id))

        input_count = tx.get_field('input_count')
        unlinked = self.db.load_tx_inputs(tx_id)
        inputs = tuple((map(self.link_output, unlinked)))
        if len(inputs) == input_count:
            tx.inputs = inputs
        else:
            tx.partial_inputs = frozenset(inputs)

    async def load_output_fields(self, output_id, field):
        """
        Loads from the DB or downloads the fields associated with a specific
        row ID.
        """
        output = self.link_output(self.db.load_output(output_id))
        if output.has_field(field):
            return

        # for the output data fields we rely on the funding transaction being
        # downloaded. the funding tx must exist.
        funding_tx = await output.funding_tx
        await funding_tx.output_count

        # if this caused a download of the tx data, reload from db
        self.link_output(self.db.load_output(output_id))
        if output.has_field(field):
            return

        # for input fields we rely on outspend status, unless we already know
        # the spending transaction
        # TODO read-at-height: check if known unspent is > read height
        #if not unlinked.has_field("spending_tx_id"):
        await self.download(esplora.API.tx_outspends(await funding_tx.txid))

        self.link_output(self.db.load_output(output_id))

    async def load_script_fields(self, script_id, field):
        """
        Loads from the DB or downloads the fields associated with a specific
        row ID.
        """
        script = self.link_script(self.db.load_script(script_id))

        if script.has_field(field):
            return

        return await self.load_script_field_by_address(await script.address, field)

    async def load_script_by_address(self, address):
        """
        This can be used when no internal ID is available yet for a transaction
        of interest.
        """
        unlinked = self.db.load_script_by_address(address)

        if unlinked is None:
            await self.download(esplora.API.address_txs(address))
            unlinked = self.db.load_script_by_address(address)

        return self.link_script(unlinked)

    async def load_script_field_by_address(self, address, field, height=None):
        """
        Load fields relating to scripts (by address).

        contiguous_bound_tx indicates the newest transactions prior to whch all
        transactions relating to this script are known, i.e. esplora's
        address/:addr/txs/chain(/:last_seen_id) endpoints were called to
        exhaustion as of fetch_newest_tx_read_height. fetch_newest_tx and
        fetch_oldest_tx being set indicate that a multi-page fetch is in
        progress.
        """

        script = await self.load_script_by_address(address)

        # TODO(read-at-height) if script.get_field('fetch_newest_tx_read_height') > self.read_height: return
        # if contiguous_bound_tx_id is set, and fetch_newest_tx_id is set and
        # fetch_newest_tx_read_height is >= read height, no need to download.

        if self.script_is_stale(script, height) and script.has_field(field): # FIXME read height is not fresh enough this is wrong
            return

        await self.load_script_txs(script, height=height)

    async def load_script_txs(self, script, height=None):
        # if the required field is still null, then we need to download
        # the set of transactions corresponding to this script
        await self.download_script_tx_pages(script) # FIXME check if contiguous bound, return?

        # download again if height is too low
        if self.script_is_stale(script, height):
            await self.download_script_tx_pages(script)

    def script_is_stale(self, script, height):
        return height is not None and script.has_field('fetch_newest_tx_read_height') and script.get_field('fetch_newest_tx_read_height') < height

    async def download_script_tx_pages(self, script):
        address = await script.address

        if not script.has_field('fetch_oldest_tx_id'):
            # no download is currently in progress, fetch the first page
            response_id = await self.download(esplora.API.address_txs(address))
            unlinked = self.db.load_script_by_address(address)
            self.link_script(unlinked)

        # fetch remaining pages until terminal response (# of txs < 25)
        # FIXME(read-at-height) make sure fetch_newest_tx_id is actually cleared, indicating that
        # contiguous_bound_tx_id was updated to match, and fetch_newest_tx_read_height applies to it
        # if it's stale, download from the start until contiguous_bound_tx_id is updated again
        while not script.has_field('contiguous_bound_tx_id'):
            last_seen = await script.fetch_oldest_tx # is script.get_value('last_seen').get_value('txid') valid here?
            response_id = await self.download(esplora.API.address_txs_continuation(address, await last_seen.txid))
            unlinked = self.db.load_script_by_address(address)
            self.link_script(unlinked)

    # FIXME should be a high level api of script itself, iterator of async
    # iterators suitable for chaining (will provide txs ordered by height) or
    # processing concurrently (duplicates possible, but sub-iterators should still be ordered)
    # if read-at-height and fetch_newest_tx_read_height < read-at-height, fetch lates
    # start returning pages as data is inserted? can check response_txs view
    # for IDs based on response_id.
    # read from contiguous_bound_tx_id to end - all txs with <= height
    async def load_script_funding_txs(self, script_id):
        return map(self.link_tx, self.db.load_known_script_funding_txs(script_id))

    async def load_script_spending_txs(self, script_id):
        # TODO check if contiguous, if not, fetch
        return map(self.link_tx, self.db.load_known_script_funding_txs(script_id))
