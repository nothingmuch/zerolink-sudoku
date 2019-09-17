import sqlite3

class Row(sqlite3.Row):
    """
    A simple wrapper around the sqlite.Row type that duck types with the
    unlinked.* types, providing .id attribute, and {has,get}_field for use with
    absorb_fields.
    """
    def __getattr__(self, name):
        try:
            return self[name]
        except IndexError:
            raise AttributeError(name)

    def get_field(self, name):
        return self[name]

    def has_field(self, name):
        return name in self.keys()

class DB(object):
    # TODO split into RelationalModel, ResponseModel? use python-sql to generate statements?

    def __init__(self, db, height=None):
        self.db = db
        self.db.row_factory = Row
        self.height = height

    def execute(self, query, param):
        try:
            return self.db.cursor().execute(query, param)
        except:
            print("SQL error", query, *param)
            raise

    def insert_response(self, path, response):
        response_id = self.execute("INSERT INTO esplora_response(request_path, response_body) VALUES (?, json(?))", (path, response)).lastrowid
        self.db.commit()
        return response_id

    def load_tx_fields(self, tx_id):
        return self.execute("select * from tx where tx.id = ?", (tx_id,)).fetchone()

    def load_tx_by_txid(self, txid):
        return self.execute("select * from tx where tx.txid = ?", (txid,)).fetchone()

    def load_tx_ids(self, ids): # by addr
        return self.execute("select tx.id from tx")

    # FIXME refactor w/ WHERE clauses?
    def load_tx_outputs(self, tx_id):
        # FIXME remove slow view workaround
        return self.execute("select *, input.id AS input_id, input.spending_tx_id, input.vin from output LEFT JOIN input ON output.id = output_id WHERE funding_tx_id = ?", (tx_id,)) # FIXME why not output.*? order clause?
        #return self.execute("select * from output_with_spend_status WHERE funding_tx_id = ?", (tx_id,))

    def load_tx_inputs(self, tx_id):
        # FIXME remove slow view workaround
        return self.execute("select *, input.id AS input_id, input.spending_tx_id, input.vin from output LEFT JOIN input ON output.id = output_id WHERE spending_tx_id = ?", (tx_id,)) # FIXME why not output.*? order clause?
        #return self.execute("select * from output_with_spend_status WHERE spending_tx_id = ?", (tx_id,))

    def load_output(self, output_id):
        return self.execute("select * from output_with_spend_status WHERE id = ? ORDER BY vout", (output_id,)).fetchone()

    def load_script(self, script_id):
        return self.execute("select * from script WHERE id = ?", (script_id,)).fetchone()

    def load_script_by_address(self, address):
        return self.execute("select * from script WHERE address = ?", (address,)).fetchone()

    def load_known_script_funding_txs(self, script_id):
        return self.execute("select tx.* from script JOIN output ON script.id = script_id JOIN tx ON funding_tx_id = tx.id WHERE script.id = ? ORDER BY height DESC", (script_id,))

    def load_known_script_spending_txs(self, script_id):
        return self.execute("select tx.* from script JOIN output ON script.id = script_id JOIN input ON output.id = input_id JOIN tx ON spending_tx_id = tx.id WHERE script.id = ?", (script_id,))

    # FIXME Script object now exists - adapt or delete
    def load_last_seen_txids(self):
        return self.execute("SELECT address, txid FROM script JOIN tx ON fetch_oldest_tx_id = tx.id WHERE contiguous_bound_tx_id IS NULL", [])

    def load_watched_addresses(self):
        return self.execute("SELECT address FROM script JOIN tx ON fetch_oldest_tx_id = tx.id WHERE fetch_newest_tx_read_height IS NOT NULL", [])
