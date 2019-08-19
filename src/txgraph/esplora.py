class EsploraError(Exception):
    def __init__(self, response):
        self.response = response
        self.message = "Did not receive 200 response code %d" % (response.status,)

    async def full_message():
        return await self.response.text()

class API(object):
    """
    Stateless helper methods for making Esplora GET requests.
    """
    def blocks_tip():
        return "blocks/tip"

    def tx(txid):
        return "tx/" + txid

    def tx_outspends(txid):
        return "tx/" + txid + '/outspends'

    def address_txs(address):
        return 'address/' + address + '/txs/chain'

    def address_txs_continuation(address, txid):
        return 'address/' + address + '/txs/chain/' + txid

class Client(object):
    def __init__(self, session, api_base='https://blockstream.info/api/'):
        self.session = session
        self.api_base = api_base

    async def get(self, path):
        async with self.session.get(self.api_base + path) as response:
            if response.status != 200:
                raise EsploraError(response)

            return await response.text()
