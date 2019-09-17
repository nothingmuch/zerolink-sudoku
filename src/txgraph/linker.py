import collections

import txgraph.unlinked as unlinked
import txgraph.linked as linked

# TODO(read-at-height) - filter out data from the future - spend height -> unspent, tx.height -> doesn't exist, # WHERE clauses?? make sure read-at-height doesn't trigger downloading, definite unspent

# TODO attr.s
class Linker(object):
    """
    The linker maintains a graph of objects such that there is a 1:1 mapping
    between id(vertex) and vertex.id (sqlite row ID).

    The linker ingests unlinked objects, creates corresponding linked objects
    if ones do not already exist, and then sets the fields of the linked object
    from the unlinked one.
    """

    def __init__(self):
        self.txs = collections.defaultdict(linked.TX)
        self.scripts = collections.defaultdict(linked.Script)
        self.outputs = collections.defaultdict(linked.Output)

    def get_tx(self, tx_id):
        """
        Find or create a linked transaction object identified by a row ID.
        """
        return self.get_obj(tx_id, self.txs)

    def get_output(self, output_id):
        """
        Find or create a linked output object identified by a row ID.
        """
        return self.get_obj(output_id, self.outputs)

    def get_script(self, script_id):
        """
        Find or create a linked script object identified by a row ID.
        """
        return self.get_obj(script_id, self.scripts)

    def get_obj(self, id_, table):
        if id_ in table:
            return table[id_]
        else:
            obj = table[id_]
            obj.id = id_
            return obj

    def link_tx(self, tx: unlinked.TX) -> linked.TX:
        """
        Incorporate an unlinked transaction object into the graph, returning
        the corresponding linked transaction.
        """
        return self.unify(tx, self.txs)

    def link_output(self, output: unlinked.Output) -> linked.Output:
        """
        Incorporate an unlinked output object into the graph, returning
        the corresponding linked output.
        """
        return self.unify(output, self.outputs, funding_tx=self.txs, spending_tx=self.txs, script=self.scripts)

    def link_script(self, script: unlinked.Script) -> linked.Script:
        """
        Incorporate an unlinked script object into the graph, returning
        the corresponding linked script.
        """
        return self.unify(script, self.scripts, contiguous_bound_tx=self.txs, fetch_newest_tx=self.txs, fetch_oldest_tx=self.txs)

    def unify(self, unlinked, table, **foreign_keys) -> object:
        """
        Generic object linking procedure:

        - Unifies on obj.id
        - Sets all the the linked object's fields from the unlinked one (should
          be idempotent or monotonic)
        - Sets all object fields (has-a relationships) based on corresponding
          _id fields (foreign keys)
        """
        linked = self.get_obj(unlinked.id, table)

        linked.absorb_fields(unlinked)

        for field, rel in foreign_keys.items():
            foreign_key_field = field + '_id'
            if unlinked.has_field(field + '_id'):
                foreign_key = unlinked.get_field(field + '_id')
                if foreign_key is not None:
                    related_object = self.get_obj(foreign_key, rel)
                    linked.__setattr__(field, related_object)
                else:
                    # TODO(read-at-height) if spending_tx_id, read height is set, and read height <= unlinked.height, set to None
                    pass

        return linked
