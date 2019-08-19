import pytest
import sqlite3
import typing
from dataclasses import *
from txgraph.base import *
from txgraph.asyncio.linker import *
from txgraph.db import *

@dataclass
class Client(object):
     __slots__=('data',)
     data: typing.Dict

     async def get(self, path):
          print("client GET", path)
          return self.data[path]

@pytest.mark.asyncio
async def test_lazy_loading():
     conn = sqlite3.connect(":memory:")

     with open('sql/schema.sql') as fp: # FIXME abspath
          conn.executescript(fp.read())

     db = DB(conn)

     client = Client(data={
          'tx/f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16': '{"txid":"f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16","version":1,"locktime":0,"vin":[{"txid":"0437cd7f8525ceed2324359c2d0ba26006d92d856a9c20fa0241106ee5a597c9","vout":0,"prevout":{"scriptpubkey":"410411db93e1dcdb8a016b49840f8c53bc1eb68a382e97b1482ecad7b148a6909a5cb2e0eaddfb84ccf9744464f82e160bfa9b8b64f9d4c03f999b8643f656b412a3ac","scriptpubkey_asm":"OP_PUSHBYTES_65 0411db93e1dcdb8a016b49840f8c53bc1eb68a382e97b1482ecad7b148a6909a5cb2e0eaddfb84ccf9744464f82e160bfa9b8b64f9d4c03f999b8643f656b412a3 OP_CHECKSIG","scriptpubkey_type":"p2pk","value":5000000000},"scriptsig":"47304402204e45e16932b8af514961a1d3a1a25fdf3f4f7732e9d624c6c61548ab5fb8cd410220181522ec8eca07de4860a4acdd12909d831cc56cbbac4622082221a8768d1d0901","scriptsig_asm":"OP_PUSHBYTES_71 304402204e45e16932b8af514961a1d3a1a25fdf3f4f7732e9d624c6c61548ab5fb8cd410220181522ec8eca07de4860a4acdd12909d831cc56cbbac4622082221a8768d1d0901","is_coinbase":false,"sequence":4294967295}],"vout":[{"scriptpubkey":"4104ae1a62fe09c5f51b13905f07f06b99a2f7159b2225f374cd378d71302fa28414e7aab37397f554a7df5f142c21c1b7303b8a0626f1baded5c72a704f7e6cd84cac","scriptpubkey_asm":"OP_PUSHBYTES_65 04ae1a62fe09c5f51b13905f07f06b99a2f7159b2225f374cd378d71302fa28414e7aab37397f554a7df5f142c21c1b7303b8a0626f1baded5c72a704f7e6cd84c OP_CHECKSIG","scriptpubkey_type":"p2pk","value":1000000000},{"scriptpubkey":"410411db93e1dcdb8a016b49840f8c53bc1eb68a382e97b1482ecad7b148a6909a5cb2e0eaddfb84ccf9744464f82e160bfa9b8b64f9d4c03f999b8643f656b412a3ac","scriptpubkey_asm":"OP_PUSHBYTES_65 0411db93e1dcdb8a016b49840f8c53bc1eb68a382e97b1482ecad7b148a6909a5cb2e0eaddfb84ccf9744464f82e160bfa9b8b64f9d4c03f999b8643f656b412a3 OP_CHECKSIG","scriptpubkey_type":"p2pk","value":4000000000}],"size":275,"weight":1100,"fee":0,"status":{"confirmed":true,"block_height":170,"block_hash":"00000000d1145790a8694403d4063f323d499e655c83426834d4ce2f8dd4a2ee","block_time":1231731025}}',
          'tx/f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16/outspends': '[{"spent":true,"txid":"ea44e97271691990157559d0bdd9959e02790c34db6c006d779e82fa5aee708e","vin":0,"status":{"confirmed":true,"block_height":92240,"block_hash":"0000000000077430a94a5376bf2af42d4b1aebdecedfa9e4f7e3f0465a84d891","block_time":1289939967}},{"spent":true,"txid":"a16f3ce4dd5deb92d98ef5cf8afeaf0775ebca408f708b2146c4fb42b41e14be","vin":0,"status":{"confirmed":true,"block_height":181,"block_hash":"00000000dc55860c8a29c58d45209318fa9e9dc2c1833a7226d86bc465afc6e5","block_time":1231740133}}]',
     })

     l = Linker(db, client)

     tx = await l.load_tx_by_txid('f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16')

     assert await tx.input_count == 1
     assert await tx.output_count == 2

     assert await (await (await tx.inputs)[0].funding_tx).txid == '0437cd7f8525ceed2324359c2d0ba26006d92d856a9c20fa0241106ee5a597c9'

     output = (await tx.outputs)[0]
     assert await output.sats == 1e9

     assert not output.has_field('spending_tx_id')
     assert not output.has_field('spending_tx')
     f = output.spending_tx_id
     assert f is not None
     assert await f is not None
     spending_tx = await output.spending_tx
     assert await spending_tx.txid == 'ea44e97271691990157559d0bdd9959e02790c34db6c006d779e82fa5aee708e'
