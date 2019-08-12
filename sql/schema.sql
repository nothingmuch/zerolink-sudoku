-- SQLite schema for a sparse bitcoin transaction graph, with trigger based parsing
-- of esplora JSON api responses (https://github.com/Blockstream/esplora/blob/master/API.md)

-- Data is populated by running:
--
--   INSERT INTO response(path, response) VALUES('blocks/tip', jsoin('... response body ...'))
--
-- This will make the response data queryable in the various esplora_* views,
-- and the propagate_tx_graph trigger will then apply the new data to the
-- (hopefully monotonic) stateful graph model.

-- The schema can be thought of as representing a bipartite graph where
-- transactions and outputs are vertices, or as a graph of transactions where
-- (input,output) pairs are labeled edges.

-- All objects are assigned internal IDs (SQLite row IDs) for use as foreign
-- keys, outputs have a funding_tx_id and a script_id, inputs have a
-- spending_tx_id and an output_id.

-- Note that the `txid` column on the tx table contains the hex transaction id,
-- whereas all (.*_tx_)?id columns refer to the row ID.

-- TODO(bikeshedding) - split up into separate files:
-- tx_graph.sql - normalized transaction graph schema + genesis block row
-- esplora.sql - response table + validation triggers
-- esplora_parsing_views.sql - json parsing views with explicit response_id
-- esplora_view.sql - insert operation views for trigger
-- propagate.sql - idempotent or monotonic propagation of json views into tx graph

-- TODO(consistency) convert INSERT OR IGNORE -> ON CONFLICT UPDATE for
-- idempotent sets
-- TODO(bikeshedding) - rename request table to esplora_response table,
-- {request,response}_id, response -> body
-- TODO(refactor) refactor WHERE to JOIN ON where appropriate
-- TODO(tests) - can sqlite SELFTEST table be used? test data in python test?
-- TODO(reorg) - reorg functionality can be implemented by adding blocks table,
-- and relating all objects to blocks
-- TODO(functionality) import block/:hash/txs responses
-- and making chain table a writable view on blocks, controlled blocks/*
-- insertion operations. graph can be a view on block_id <-> height PK
-- conversion, preserving current schema instead of cascade delete, recursively
-- set txs as orphanned?
-- TODO(refactor) views for the SELECTs of the INSERT ... SELECT parts of the
-- trigger, trigger itself shouldn't contain any logic. how to model updates?
-- TODO(functionality) views for enumearting partial/missing information (txs,
-- addresses w/ fetches in progress)
-- TODO(portability) port to postgres? requires different handling of NULL on
-- address field (can switch to relying on scripthash for API calls). json_each
-- and window functions should be compatible, but json_tree ismissing (cte on
-- json_each?) as is json_remove
-- TODO(bikeshedding) - rename existing esplora_response_* views to
-- esplora_parse_*, rename esplora_response_txs to _tx_json
-- TODO refactor trigger:
-- - requires deterministic trigger ordering, even with cascading triggers
--   ran into some issues (spurious NULL values)
-- - redo as views ( response_id, table.* ) x { chain, script_type, script, tx, output, input }
--   triggers should only be:
--     insert into table (select table.*
--                          from esplora_response_{table}
--                         where response_id = new.response_id)
--     on conflict update set ...
-- - separate by request type



-- table? chain ( height integer primary key, block_id intger not null references block(id))
-- table block ( id integer primary key, height integer not null, hash varchar not null unique, prev varchar, time, tx_count)
-- table block_entry ( id integer, tx_id )
-- view chain_tx_order ( i integer primary key, tx_id not null references tx(id) ) 

PRAGMA foreign_keys = ON; -- TODO ensure this is sticky
-- TODO(consistency) case sensitive like pragma


-- known blocks are tracked in the chain table,
-- without reorg support this is a sparse append only list
-- can be pruned DELETE WHERE height NOT IN tx.height
-- parent & time can be null because sometimes only the hash is known at a block height
CREATE TABLE chain
( height INTEGER PRIMARY KEY
, hash CHAR(32) UNIQUE NOT NULL
, parent CHAR(32)
, time INTEGER -- nominal block time in epoch seconds
);

-- TODO(reorg) - this should be linked to a blocks table
-- blocks table to hold (hash, parent, time), chain relation becomes an order relation on all blocks
-- blocks contain txs similarly to input object (block_id, tx_id, offset)
-- fetch_index for block pagination

-- this view is used to query the height of the chain tip
-- it's relied on by several triggers and views below
CREATE VIEW chain_tip_height
AS SELECT max(height) as height FROM chain;

-- for height to always be not null and >= 0, initialize with a random value
INSERT INTO chain
VALUES ( 0
       , '000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f'
       , '0000000000000000000000000000000000000000000000000000000000000000'
       , 1231006505
       );

-- note subtle difference between txid, and id, whose foreign keys are named *_tx_id
-- txid is the hash of the transaction, whereas id and tx_id use the sqlite row id
-- entries with NULL txids represent that a set of outputs is known to be
-- unspent as of some block height, these are created from positive evidence
-- ({spent: false} in outspends responses)
CREATE TABLE tx
( id INTEGER PRIMARY KEY
, txid CHAR(32) UNIQUE NOT NULL
, height INTEGER REFERENCES chain(height) -- TODO(mempool) TODO(reorg) NULL height represents unknown block height, not unconfirmed
, input_count INTEGER -- TODO(consistency) constrain to match input rel cardinality
, output_count INTEGER -- TODO(consistency) constrain to match output rel cardinality
);

-- an enum table for script types (p2kh, p2wpkh...)
-- TODO(bikeshedding) for where clauses a text column is probably easier to use than a relation. but maybe a view is enough? is there a justification for more complex queries?
CREATE TABLE script_type
( id INTEGER PRIMARY KEY
, type VARCHAR UNIQUE NOT NULL
);

-- scripts keep track of a specific output condition, which may or may not have
-- a human readable address associated with it, but always has dissassembled bitcoin script
-- fetch_* and contiguous_bound_tx_id keep track of paged responses when enumerating
-- transactions associated with this script/address
CREATE TABLE script
( id INTEGER PRIMARY KEY
, asm VARCHAR UNIQUE NOT NULL                         -- human readable script
, address VARCHAR UNIQUE                              -- human readable address when available -- FIXME not portable, null uniqueness
, script_type_id NOT NULL REFERENCES script_type(id)
, fetch_newest_tx_id INTEGER REFERENCES tx(id)         -- ID of the first tx in a previous 
, fetch_newest_tx_read_height INTEGER REFERENCES chain(height) -- the block height at which the upper bound transaction that transaction is known to be newest TODO(mempool) TODO(reorg)
, fetch_oldest_tx_id INTEGER REFERENCES tx(id)         -- 
, contiguous_bound_tx_id INTEGER REFERENCES tx(id)     -- refers  which all transactions have been fetched.
);

-- transactions have many outputs, indexed by vout, an amount
-- transactions are linked by inputs, which signify spending
CREATE TABLE output
( id INTEGER PRIMARY KEY
, funding_tx_id INTEGER NOT NULL REFERENCES tx(id)
, vout INTEGER NOT NULL
, script_id INTEGER REFERENCES script(id) -- can be null when outspends response precedes corresponding transaction response
, sats INTEGER                            -- can be null when outspends response precedes corresponding transaction response
, CONSTRAINT tx_vout UNIQUE (funding_tx_id, vout)
);

-- inputs exclusively spend outputs - 1:1 relationship - TODO(reorg) TODO(mempool), remove this constraint & model double spending
-- this ensures that the output's spending transaction is consistent with the current chain state
CREATE TABLE input
( id INTEGER PRIMARY KEY
, spending_tx_id NOT NULL REFERENCES tx(id)
, vin INTEGER -- TODO(consistency) when tx.txid is not null, enforce not null?
, output_id INTEGER NOT NULL REFERENCES output(id) UNIQUE -- TODO(reorg) remove unique constraint
, CONSTRAINT tx_vin UNIQUE (spending_tx_id, vin)
);



-- convenience views on tx model


-- the edge set of the known transaction graph
-- can be used to query UTXO set intersection w/ known outputs at a given height
-- by restricting funding_height to interval and treating spending_height >= threshold
-- as unspent
-- TODO id, height,id, all as valid field sets for unlinked.TX?
-- or just remove this view?
CREATE VIEW tx_subgraph AS
SELECT
  funding_tx.height AS funding_height, funding_tx_id, vout,
  spending_tx.height AS spending_height, spending_tx_id, vin, sats
FROM tx AS funding_tx
JOIN output ON funding_tx.id = output.funding_tx_id
JOIN input ON output.id = output_id
JOIN tx ON spending_tx_id = tx.id;


--TODO
-- script -> outputs view taking into account contiguous_bound_tx_id w/ marker column? is_full_

-- fully known vs. implied tx set (implied means we know of a tx from a prevout
-- or a spent status but haven't fetched the tx itself)

-- recursive graph queries in sqlite using CTEs? depth limiting?

-- excludes null spending txs, can be further restricted with height <= in where
-- clause
-- fixme how does this work with sqlite deserialization?
CREATE VIEW confirmed_tx_graph AS
SELECT funding_tx.id fundingtx_id, vout, spending_tx.txid AS spending_txid, vin, sats, spending_tx.height
FROM tx as funding_tx
JOIN output ON funding_tx.id = output.funding_tx_id
JOIN input ON output.id = input.output_id
JOIN tx AS spending_tx ON input.spending_tx_id = spending_tx.id
WHERE spending_tx.txid IS NOT NULL;

-- UTXO set with height of individual observations
CREATE VIEW utxo_set AS
SELECT funding_tx.txid AS funding_txid, output.vout, sats, spending_tx.height as height
FROM tx AS spending_tx
JOIN input ON spending_txid.id = input.spending_txid
JOIN output ON input.output_id = output.id
JOIN tx AS funding_tx ON output.funding_tx_id = funding_tx.id
WHERE spending_tx.txid IS NULL; -- TODO - OR spending_tx.height <= read_height;, remove IS NULL constraint
-- proper UTXO set at height can be computed at a given height by making join
-- condition a reference to the height instead includeof txid IS NULL and adding WHERE
-- clause for txid IS NULL OR tx.height <= read_height

CREATE VIEW outspends AS
SELECT
  output.*, input.id as input_id,
  CASE
    -- suppress spending_tx_id when the spending tx is a null (unspent marker)
    -- since the full information is represented in the block height and NULL value
    WHEN tx.txid IS NULL THEN NULL -- TODO - check input.vin NULL to avoid joining tx table a second time?
    ELSE spending_tx_id
  END as spending_tx_id,
  vin, height
FROM output
LEFT JOIN input ON output.id = input.output_id
LEFT JOIN tx ON input.spending_tx_id = tx.id;

CREATE VIEW partial_address_funding_txs AS
SELECT tx.*, output.id as output_id, funding_tx_id, vout, script_id, sats, script.address
FROM script -- JOIN script_type ON script_type_id = script.id
JOIN output ON script.id = output.script_id
JOIN tx ON output.funding_tx_id = tx.id;

CREATE VIEW partial_address_spending_txs AS
SELECT tx.*, output.id as output_id, funding_tx_id, vout, script_id, sats, script.address
FROM script -- JOIN script_type ON script_type_id = script.id
JOIN output ON script.id = output.script_id
JOIN input ON output.id = input.output_id
JOIN tx ON input.spending_tx_id = tx.id;

-- if contiguous_bound_tx_id is set, then the full history up to that ID is known
CREATE VIEW address_txs AS
SELECT tx.*, output.*, script.address
FROM script JOIN script_type ON script_type_id = script.id
JOIN output ON script.id = output.script_id
JOIN input ON output.id = input.output_id
JOIN tx ON input.spending_tx_id = tx.id = tx.id
WHERE script.contiguous_bound_tx_id IS NOT NULL;


-- TODO create views for typical load queries




CREATE TABLE electrum_response
( response_id INTEGER PRIMARY KEY
, timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
, prior_height INTEGER -- DEFAULT (SELECT MAX(height) FROM chain) - implemented with trigger
, request_path VARCHAR NOT NULL -- should really be JSON of request method
, response_body JSON
);






-- esplora api with responses are stored in this table
-- https://github.com/Blockstream/esplora/blob/master/API.md
-- can be pruned with e.g. DELETE where prior_height < (SELECT max(height) FROM chain)-100
CREATE TABLE esplora_response
( response_id INTEGER PRIMARY KEY
, timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
, prior_height INTEGER -- DEFAULT (SELECT MAX(height) FROM chain) - implemented with trigger
, request_path VARCHAR NOT NULL -- GET request path - TODO create index for LIKE patterns?
, response_body JSON
);

-- todo add timestamp from request? or unique constraint & max(height) upsert?
CREATE TABLE esplora_known_unspent
( id INTEGER PRIMARY KEY
, height INTEGER NOT NULL REFERENCES chain(height)
, output_id INTEGER NOT NULL REFERENCES output(id)
, response_id INTEGER NOT NULL REFERENCES esplora_response(response_id)
);


CREATE VIEW esplora_unspent_height AS
SELECT output_id, max(height) as height
  FROM esplora_known_unspent
 GROUP BY output_id;

-- FIXME this view is really slow - redo as two left joins w/ coalesce output?
-- CREATE VIEW output_with_spend_status AS
-- SELECT *
--   FROM output
-- LEFT JOIN (SELECT * FROM (
--     SELECT output_id, height, spending_tx_id, vin
--       FROM input JOIN tx ON spending_tx_id = tx.id
--   UNION
--     SELECT output_id, height, NULL as spending_tx_id, NULL as vin
--       FROM esplora_unspent_height
--   ) GROUP BY output_id) ON output.id = output_id;

-- FIXME better, but is it necessary?
-- CREATE VIEW output_with_spend_status AS
--   SELECT output.*, NULL as input_id, NULL as spending_tx_id, NULL as vin, height
--     FROM output LEFT JOIN input ON output.id = input.output_id
--     JOIN esplora_unspent_height ON output.id = esplora_unspent_height.output_id
--     WHERE input.spending_tx_id IS NULL
--     -- TODO where no input exists to avoid returning previous unspent height for now spent tx
-- UNION
--   SELECT output.*, input.id as input_id, spending_tx_id, vin, spending_tx.height
--     FROM output
--     LEFT JOIN input ON output.id = output_id
--     LEFT JOIN tx AS spending_tx ON spending_tx_id = spending_tx.id;

CREATE VIEW output_with_spend_status AS
SELECT output.*, input.id AS input_id, coalesce(tx.height, esplora_unspent_height.height) as height, spending_tx_id, vin
FROM output
LEFT JOIN esplora_unspent_height ON output.id = esplora_unspent_height.output_id
LEFT JOIN input ON output.id = input.output_id LEFT JOIN tx ON spending_tx_id = tx.id ;



-- this trigger will reject any responses which do not parse as json
-- enforces sanity since the esplora_* views below rely on json for extraction
-- TODO(consistency) there's no structural validation in case of api changes?
CREATE TRIGGER validate_response_json
BEFORE INSERT ON esplora_response
BEGIN
  SELECT CASE
    WHEN NOT json_valid(new.response_body) THEN raise(ABORT, 'invalid response JSON')
  END;
END;

-- record a lower bound on block height for requests
CREATE TRIGGER set_response_prior_height
AFTER INSERT ON esplora_response -- FIXME why doesn't before insert work?
WHEN new.prior_height IS NULL
BEGIN
  -- TODO(bikeshedding) FIXME why does CTE produce a syntax error? -- WITH tip AS (SELECT max(height) FROM chain)
  UPDATE esplora_response
  -- this value is the highest known block from right before the response was inserted
  -- note that this needs to run before before propagate_tx_graph trigger
  -- it should evaluate the same as esplora_implied_height at this stage # FIXME seems i was wrong about trigger sequencing
  SET prior_height = (SELECT height from chain_tip_height)
  WHERE response_id = new.response_id;
END;



-- these triggers crudely reject responses on another chain
-- in the future they can be extended for reorg handling, not just detection

-- reject mismatched hashes in block-height/:height responses
CREATE TRIGGER validate_block_height_hash
BEFORE INSERT ON esplora_response
WHEN new.request_path LIKE 'block-height/%'
BEGIN
  SELECT
  CASE
  -- TODO handle reorg, create orphans from chain data and cascade delete
  -- find nulltx for height and recreate inputs with it
    WHEN json_extract(new.response_body, '$') != (SELECT hash FROM chain WHERE height = CAST(ltrim(new.request_path, 'block-height/') AS INTEGER) )
      THEN raise(ABORT, 'block height hash mismatch (TODO(reorg))') -- grr, can't add values to error
  END;
END;

CREATE TRIGGER validate_blocks_hashes
BEFORE INSERT ON esplora_response
WHEN new.request_path LIKE 'block%' -- blocks/tip, etc
BEGIN
  SELECT
  CASE
    WHEN 0 < (SELECT COUNT(*) FROM chain, json_each(new.response_body)
               WHERE height = json_extract(value, '$.height')
                 AND hash != json_extract(value, '$.id'))
      THEN raise(ABORT, 'blocks tip hash mismatch(es) (TODO(reorg))')
  END;
END;


CREATE TRIGGER validate_tx_block_hash
BEFORE INSERT ON esplora_response
WHEN new.request_path LIKE 'tx/%' AND new.request_path NOT LIKE 'tx/%/outspends'
BEGIN
  SELECT
  CASE
  WHEN json_extract(new.response_body, '$.status.block_hash') != (SELECT hash FROM chain WHERE height = json_extract(new.response_body, '$.status.block_height'))
    THEN raise (ABORT, 'tx status hash mismatch (TODO(reorg))')
  END;
END;

CREATE TRIGGER validate_tx_outspends_block_hashes
BEFORE INSERT ON esplora_response
WHEN new.request_path LIKE 'tx/%/outspends'
-- OR new.request_path LIKE 'address/%/txs%' -- FIXME same code as validate_tx_outspends_block_hashes below, except error message. refactor?
BEGIN
  SELECT
    CASE
    WHEN 0 < (SELECT COUNT(*) FROM chain, json_each(new.response_body)
               WHERE height = json_extract(value, '$.status.block_height')
                 AND hash != json_extract(value, '$.status.block_hash'))
     THEN raise(ABORT, 'tx outspends hash mismatch(es) (TODO(reorg))')
  END;
END;

CREATE TRIGGER validate_address_txs_block_hashes
BEFORE INSERT ON esplora_response
WHEN new.request_path LIKE 'address/%/txs%' -- allow trailing patterns: (/chain(/:last_seen_txid)?)?
BEGIN
  SELECT
  CASE
    WHEN 0 < (SELECT COUNT(*) FROM chain, json_each(new.response_body)
               WHERE height = json_extract(value, '$.status.block_height')
                 AND hash != json_extract(value, '$.status.block_hash'))
      THEN raise(ABORT, 'address txs hash mismatch(es) (TODO(reorg))')
  END;
END;







-- esplora_* views extract data out of JSON esplora_responses to aid in normalization in
-- the trigger below, and for debugging


-- parse hashes out of block height API calls
CREATE VIEW esplora_block_height_assertions AS
SELECT response_id
     , CAST(ltrim(esplora_response.request_path, 'block-height/') AS INTEGER) as height
     , json_extract(response_body, '$') as hash
  FROM esplora_response WHERE request_path LIKE 'block-height/%';

-- parse blocks responses
CREATE VIEW esplora_blocks_assertions AS
SELECT response_id
     , json_extract(value, '$.height') as height
     , json_extract(value, '$.id') as hash
     , json_extract(value, '$.previousblockhash') as parent
     , json_extract(value, '$.timestamp') as time
FROM esplora_response, json_each(response_body) WHERE esplora_response.request_path LIKE 'blocks%'
UNION
SELECT response_id
     , json_extract(response_body, '$.height') as height
     , json_extract(response_body, '$.id') as hash
     , json_extract(response_body, '$.previousblockhash') as parent
     , json_extract(response_body, '$.timestamp') as time
FROM esplora_response WHERE esplora_response.request_path LIKE 'block/%';

-- extract the value of any property named scriptpubkey_type
-- TODO(bikeshedding) might be easier esp. in WHERE clauses to merge with script table as a string column instead of as a relation
CREATE VIEW esplora_script_types AS
SELECT response_id
     , value as type
FROM esplora_response, json_tree(response_body)
WHERE key = 'scriptpubkey_type';

-- recursively extract known blocks from tx/:txid, address/:addr/txs% and tx/:txid/outspends responses
CREATE VIEW esplora_status_block_assertions AS
SELECT response_id
     , json_extract(value, '$.block_height') as height
     , json_extract(value, '$.block_hash') as hash
     , json_extract(value, '$.block_time') as time
FROM esplora_response, json_tree(response_body)
WHERE key = 'status';

-- this view is the basis of other transaction data parsers
-- tx/:txid produces one row, whereas address/:addr/txs% produces a 1:n relation
-- by building on this other views process the json transaction data with one code path
CREATE VIEW esplora_response_txs AS
  SELECT response_id
       , key as idx
       , json_extract(value, '$.txid') as txid
       , value AS tx_json
       , tx.output_count IS NOT NULL AND (select count(*) FROM output WHERE funding_tx_id = tx.id AND script_id IS NOT NULL AND sats IS NOT NULL ) == tx.output_count as is_known
  FROM esplora_response JOIN json_each(response_body, '$')
  LEFT JOIN tx ON json_extract(value, '$.txid') == tx.txid
  WHERE request_path     LIKE 'address/%/txs%'
UNION
  SELECT response_id
       , 0 as idx
       , json_extract(response_body, '$.txid') as txid
       , response_body AS tx_json
       , tx.output_count IS NOT NULL AND (select count(*) FROM output WHERE funding_tx_id = tx.id AND script_id IS NOT NULL AND sats IS NOT NULL ) == tx.output_count as is_known
  FROM esplora_response
  LEFT JOIN tx ON json_extract(response_body, '$.txid') == tx.txid
  WHERE request_path     LIKE 'tx/%'
    AND request_path NOT LIKE 'tx/%/outspends';


-- extract transaction confirmation status from tx/:txid, addresss/:addr/txs but not outspends
-- note that this does not recurse with json_tree like esplora_status_block_assertions above
CREATE VIEW esplora_tx_confirmations
AS SELECT response_id
        ,  txid -- json_extract(tx_json, '$.txid') as txid -- TODO replace all these with just `txid`
        ,  height -- json_extract(tx_json, '$.status.block_height') as height
        ,  hash -- json_extract(tx_json, '$.status.block_hash') as hash
        ,  time -- json_extract(tx_json, '$.status.block_time') as time
FROM esplora_response_txs_cache;

-- combine all known block hashes assertions
-- these will be checked and autovivified in the chain table
CREATE VIEW esplora_combined_block_assertions
AS    SELECT * FROM esplora_block_height_assertions
UNION SELECT response_id, height, hash FROM esplora_blocks_assertions
UNION SELECT response_id, height, hash FROM esplora_status_block_assertions
UNION SELECT response_id, height, hash FROM esplora_tx_confirmations;


-- find highest block size implied by the response data
-- TODO also handle blocks responses, not needed right now since this is for outspends
CREATE VIEW esplora_implied_height AS
SELECT response_id, max(json_extract(value, '$.block_height')) as height
FROM esplora_response, json_tree(response_body), chain_tip_height
WHERE key = 'status'
GROUP BY response_id;

-- extract funded (new) outputs from given transactions
CREATE VIEW esplora_tx_vout
AS SELECT response_id
        , txid -- json_extract(tx_json, '$.txid') as txid
        , key as vout
        , json_extract(value, '$.scriptpubkey_address') AS address
        , json_extract(value, '$.scriptpubkey_asm') AS asm
        , json_extract(value, '$.scriptpubkey_type') AS script_type
        , json_extract(value, '$.value') AS sats
     FROM esplora_response_txs_cache, json_each(tx_json, '$.vout');

-- extract spent outputs from given transactions
-- TODO consider merging with tx_inputs?
CREATE VIEW esplora_tx_prevout AS
SELECT response_id
     , json_extract(value, '$.txid') as txid
     , json_extract(value, '$.vout') as vout
     , json_extract(value, '$.prevout.scriptpubkey_address') AS address
     , json_extract(value, '$.prevout.scriptpubkey_asm') AS asm
     , json_extract(value, '$.prevout.scriptpubkey_type') AS script_type
     , json_extract(value, '$.prevout.value') AS sats
  FROM esplora_response_txs_cache, json_each(tx_json, '$.vin');

-- combined spent and funded outputs (vout & prevout)
CREATE VIEW esplora_outputs AS -- FIXME(bikeshedding) inconsistent naming
SELECT * FROM esplora_tx_vout UNION SELECT * FROM esplora_tx_prevout;

-- extract inputs from given transactions
-- TODO consider merging with tx_prevout?
CREATE VIEW esplora_tx_inputs AS
SELECT response_id
     , txid as spending_txid -- json_extract(tx_json, '$.txid') as spending_txid
     , key as vin
     , json_extract(value, '$.txid') AS txid
     , json_extract(value, '$.vout') AS vout
 FROM esplora_response_txs_cache, json_each(tx_json, '$.vin');

-- extract lengths of input/output vectors from given transactions
-- used to keep track of whether we have the full sets of inputs/outputs related
-- to a transaction
CREATE VIEW esplora_tx_vin_vout_counts AS -- TODO consolidate with esplora_response_txs
SELECT response_id
     , txid -- json_extract(tx_json, '$.txid') AS txid
     , CASE WHEN json_extract(tx_json, '$.vin[0].is_coinbase') THEN 0 ELSE json_array_length(tx_json, '$.vin') END AS input_count
     , json_array_length(tx_json, '$.vout') AS output_count
  FROM esplora_response_txs_cache;


-- extract the confirmation/spending status from tx/:txid/outspends responses
-- this can refer to transactions we don't yet know about
CREATE VIEW esplora_outspend_status
AS SELECT response_id
        , substr(request_path, 4, 64) AS funding_txid
        , key AS vout
        , json_extract(value, '$.txid') AS spending_txid -- NULL means unspent
        , json_extract(value, '$.vin') AS vin
        , coalesce(json_extract(value, '$.status.block_height'), prior_height) as height -- unspent status is assumed to be as of prior height, but spent outputs have a known height for spending tx
     FROM esplora_response, json_each(response_body)
    WHERE request_path LIKE 'tx/%/outspends';


-- FIXME can this be removed?
-- CREATE VIEW esplora_response_new_txns AS
-- SELECT response_id, tx.id
--   FROM esplora_tx_confirmations JOIN tx ON txid;

-- CREATE VIEW esplora_response_updated_outputs AS
-- SELECT response_id, output.id AS output_id, input.id AS input_id,
--        CASE
--        -- suppress spending_tx_id when the spending tx is a null (unspent marker)
--        -- since the full information is represented in the block height and NULL value
--          WHEN spending_tx.txid IS NULL THEN NULL -- TODO - check input.vin NULL to avoid joining tx table a second time?
--          ELSE spending_tx_id
--        END as spending_tx_id
--   FROM esplora_outspend_status
--   JOIN tx AS funding_tx ON esplora_outspend_status.funding_txid = funding_tx.txid
--   JOIN output ON funding_tx.id = funding_tx_id AND esplora_outspend_status.vout = output.vout
--   JOIN input ON output.id = input.output_id
--   JOIN tx AS spending_tx ON spending_tx_id = spending_tx.id;





-- these views assume the insert trigger has finished updating the graph, and
-- join between esplora data and the graph model. they are used to keep track of
-- of the fetch status of address/:addr/txs/chain requests


CREATE VIEW esplora_response_tx_ids AS
SELECT response_id
     , idx
     , tx.id
FROM esplora_response_txs_cache JOIN tx USING(txid);

-- This view extracts the address associated with an address/:addr/txs/chain
-- response
CREATE VIEW esplora_response_address AS
SELECT response_id, script.id AS script_id, tx.id AS last_seen_tx_id
FROM (SELECT response_id
           , substr(substr(request_path, 0, instr(request_path, '/txs/chain')), 9) AS address
           , CASE
               WHEN instr(request_path, '/txs/chain/') = 0 THEN NULL
               ELSE substr(request_path, instr(request_path, '/txs/chain/') + 11)
             END AS txid
        FROM esplora_response
       WHERE request_path LIKE 'address/%/txs/chain%')
JOIN script USING(address)
LEFT JOIN tx USING(txid);

-- This view extracts information from pages transaction responses
-- esplora limits transaction responses to 25 transactions, and
-- continuation pages are fetched by specifying the txid of the last
-- entry as part of the next request.
CREATE VIEW esplora_response_address_txs_page_boundaries AS
SELECT response_id
     , script_id
     , last_seen_tx_id
     , coalesce(count, 0) as count
     , newest_tx.id AS response_newest_tx_id
     , oldest_tx.id AS response_oldest_tx_id
     , ifnull(count < 25, 1) AS terminal
  FROM esplora_response_address
  LEFT JOIN (SELECT response_id
             , count(*) AS count
             , newest_txid
             , oldest_txid
          FROM esplora_response_txs_cache -- see below
         GROUP BY response_id
       ) USING(response_id)
  -- FIXME this is pathologically slow so instead we rely on the cache table to be updated in the trigger
  -- JOIN (SELECT DISTINCT response_id
  --                      , count(*) OVER win AS count
  --                      , first_value(txid) OVER win AS newest_txid
  --                      , last_value(txid) OVER win AS oldest_txid
  --         FROM esplora_response_txs
  --         WINDOW win AS (PARTITION BY response_id
  --           ORDER BY idx
  --           RANGE BETWEEN UNBOUNDED PRECEDING
  --           AND UNBOUNDED FOLLOWING)) USING(response_id)
  LEFT JOIN tx AS newest_tx ON newest_tx.txid = newest_txid
  LEFT JOIN tx AS oldest_tx ON oldest_tx.txid = oldest_txid;

-- FIXME this is a horrible hack, and should be removed
-- only really needed by esplora_response_address_txs_page_boundaries which is otherwise pathologically slow
-- cache the above view since it's evaluated a lot
CREATE TABLE esplora_response_txs_cache
( response_id INTEGER NOT NULL REFERENCES esplora_response(response_id)
, idx INTEGER NOT NULL
, newest_txid VARCHAR NOT NULL
, oldest_txid VARCHAR NOT NULL
, tx_json JSON NOT NULL -- note that this has the $.vin, $.vout and $.status elements removed when full tx is already known
, txid VARCHAR NOT NULL
, height VARCHAR NOT NULL
, hash VARCHAR NOT NULL
, time VARCHAR NOT NULL
, is_known BOOLEAN NOT NULL
-- TODO additional fields, memory table?
, CONSTRAINT tx_vout UNIQUE (response_id, idx)
);





-- update the transaction graph whenever new esplora responses are added
-- operations must be idempotent inserts or monotonic upserts of optional
-- values (where bottom is NULL)
CREATE TRIGGER propagate_tx_graph_chain
AFTER INSERT ON esplora_response
BEGIN
  INSERT INTO esplora_response_txs_cache -- TODO(consistency) ON CONFLICT to check json, raise(ABORT) if mismatched?
  SELECT response_id
       , idx
       , first_value(txid) OVER win AS newest_txid
       , last_value(txid) OVER win AS oldest_txid
       , CASE -- performance hack - omit input/output/status fields when tx is already fully known
           WHEN is_known THEN json_remove(tx_json, '$.vin', '$.vout', '$.status')
           ELSE tx_json
         END as tx_json
       , txid
       , json_extract(tx_json, '$.status.block_height') as height
       , json_extract(tx_json, '$.status.block_hash') as hash
       , json_extract(tx_json, '$.status.block_time') as time
       , is_known
    FROM esplora_response_txs
   WHERE esplora_response_txs.response_id = new.response_id
  WINDOW win AS (PARTITION BY response_id
                     ORDER BY idx
                     RANGE BETWEEN UNBOUNDED PRECEDING
                       AND UNBOUNDED FOLLOWING);


  -- FIXME skipping of graph updates is disabled because it breaks updating of
  -- fetch information, see commented out update_script_tx_boundaries_on_fetch
  -- below for more details
  -- SELECT
  -- CASE
  --   WHEN
  --     (SELECT sum(is_known) FROM esplora_response_txs_cache WHERE response_id = new.response_id)
  --       ==
  --     (SELECT count(*) FROM esplora_response_txs_cache WHERE response_id = new.response_id)
  --   THEN raise(IGNORE)
  -- END;

  -- 1. chain

  -- propagate full block information from blocks responses
  INSERT INTO chain
  SELECT height, hash, parent, time FROM esplora_blocks_assertions
  WHERE esplora_blocks_assertions.response_id = new.response_id
  -- WHERE time IS NOT NULL
  ON CONFLICT(height) DO UPDATE SET
    hash = CASE
      WHEN hash IS     NULL THEN excluded.hash
      WHEN hash IS NOT NULL AND hash == excluded.hash THEN hash
      -- ELSE coalesce(hash, excluded.hash)
      ELSE raise(ABORT, 'mismatched block hash')
    END,
    parent = CASE
      WHEN parent IS     NULL THEN excluded.parent
      WHEN parent IS NOT NULL AND parent == excluded.parent THEN parent
      -- ELSE coalesce(parent, excluded.parent)
      ELSE raise(ABORT, 'mismatched parent block hash')
    END,
    time = CASE
      WHEN time IS     NULL THEN excluded.time
      WHEN time IS NOT NULL AND time == excluded.time THEN time
      -- ELSE coalesce(time, excluded.time)
      ELSE raise(ABORT, 'mismatched block time')
    END;

  -- propagate partial block information (<hash,height> assertions) extracted from transaction status
  -- TODO(reorg) responses which include mismatching hashes are rejected, but this will have to be a cascade delete once that's relaxed
  INSERT OR IGNORE INTO chain (height, hash)
  SELECT height, hash FROM esplora_combined_block_assertions
  WHERE esplora_combined_block_assertions.response_id = new.response_id;




  -- 2. script_type
  -- autovivify script types to satisfy foreign key constraints
  INSERT OR IGNORE INTO script_type(type)
  SELECT type FROM esplora_script_types
  WHERE esplora_script_types.response_id = new.response_id;



  -- 3. script - see also fetch bounds update trigger below
  -- propagate scripts from outputs & prevouts
  INSERT OR IGNORE INTO script(script_type_id, asm, address)
  SELECT script_type.id, asm, address
    FROM esplora_outputs, script_type
   WHERE script_type.type = esplora_outputs.script_type
     AND esplora_outputs.response_id = new.response_id;



  -- 4. tx - several variants here, for tx (single or batch) and for outspends responses

  -- create stubs for new confirmed transactions
  INSERT INTO tx(txid, height)
  SELECT DISTINCT txid, height
    FROM esplora_tx_confirmations
   WHERE esplora_tx_confirmations.response_id = new.response_id
  ON CONFLICT(txid) DO UPDATE SET height = CASE
    WHEN height IS     NULL THEN excluded.height
    WHEN height IS NOT NULL AND height == coalesce(excluded.height, height) THEN height
    ELSE raise(ABORT, 'mismatched height (can only differ if one is NULL)')
  END;

  -- create stubs for spent outputs' funding transactions
  INSERT OR IGNORE INTO tx(txid) -- block height not known
  SELECT txid
    FROM esplora_outputs
   WHERE esplora_outputs.response_id = new.response_id;

  -- create stubs for outspend responses' outputs' funding transactions
  INSERT OR IGNORE INTO tx(txid)
  SELECT DISTINCT funding_txid
    FROM esplora_outspend_status
   WHERE funding_txid IS NOT NULL
     AND esplora_outspend_status.response_id = new.response_id;

  -- create stubs for outspend responses' outputs' spending transactions
  INSERT OR IGNORE INTO tx(txid, height) SELECT spending_txid, height FROM esplora_outspend_status
   WHERE spending_txid IS NOT NULL AND height IS NOT NULL;



  -- 5. outputs - again both tx & outspends response variants exist TODO(refactor)

  -- reify tx outputs
  INSERT INTO output(funding_tx_id, vout, script_id, sats)
  SELECT tx.id, vout, script.id, sats
  FROM esplora_outputs JOIN tx USING(txid) JOIN script USING(asm)
  WHERE esplora_outputs.response_id = new.response_id
  ORDER BY tx.id, vout ASC
  ON CONFLICT(funding_tx_id, vout)
  DO UPDATE
  SET script_id = CASE
        WHEN script_id IS     NULL THEN excluded.script_id
        WHEN script_id IS NOT NULL AND script_id == excluded.script_id THEN script_id
        ELSE raise(ABORT, 'mismatched output script')
      END
    , sats = CASE
        WHEN sats IS     NULL THEN excluded.sats
        WHEN sats IS NOT NULL AND sats == excluded.sats  THEN sats
        ELSE raise(ABORT, 'mismatched output amount')
      END;

  -- reify outspends outputs
  INSERT OR IGNORE INTO output(funding_tx_id, vout)
  SELECT funding_tx.id, vout
    FROM esplora_outspend_status JOIN tx as funding_tx
      ON esplora_outspend_status.funding_txid = funding_tx.txid
   WHERE esplora_outspend_status.response_id = new.response_id
   ORDER BY funding_tx.id, vout ASC; -- FIXME on conflict update?



  -- 6. inputs - keep track of spent status of outputs

  -- forward link outputs to spending transactions
  INSERT INTO input(spending_tx_id, vin, output_id)
  SELECT spending_tx.id, vin, output.id
    FROM esplora_tx_inputs, tx AS spending_tx, tx AS funding_tx, output -- TODO refactor join
   WHERE esplora_tx_inputs.spending_txid = spending_tx.txid
     AND esplora_tx_inputs.txid = funding_tx.txid
     AND output.funding_tx_id = funding_tx.id AND output.vout = esplora_tx_inputs.vout
     AND esplora_tx_inputs.response_id = new.response_id
   ORDER BY spending_tx.id, vin ASC
  ON CONFLICT(output_id) -- TODO remove vestiges of known unspent tracking - can all this be deleted?
  DO UPDATE
  SET spending_tx_id = CASE
        WHEN spending_tx_id IS     NULL THEN excluded.spending_tx_id
        WHEN spending_tx_id IS NOT NULL AND spending_tx_id == excluded.spending_tx_id THEN spending_tx_id
        ELSE raise(ABORT, 'mismatched spending tx')
      END
    , vin = CASE
        WHEN vin IS     NULL THEN excluded.vin
        WHEN vin IS NOT NULL AND vin == excluded.vin  THEN vin
        ELSE raise(ABORT, 'mismatched input index')
      END;

  -- propagate spending txs' inputs from confirmed outspend status
  INSERT OR IGNORE INTO input(spending_tx_id, vin, output_id)
  SELECT spending_tx.id as spending_tx_id, esplora_outspend_status.vin, output.id as output_id--, funding_tx.id as funding_txid, esplora_outspend_status.vout
    FROM output
    JOIN tx as funding_tx ON output.funding_tx_id = funding_tx.id
    JOIN esplora_outspend_status ON esplora_outspend_status.funding_txid = funding_tx.txid AND output.vout = esplora_outspend_status.vout
    JOIN tx as spending_tx ON (
        esplora_outspend_status.spending_txid = spending_tx.txid
          OR
        (spending_tx.txid IS NULL AND esplora_outspend_status.spending_txid IS NULL)
      ) AND spending_tx.height = esplora_outspend_status.height
   WHERE esplora_outspend_status.response_id = new.response_id
   ORDER BY spending_tx.id ASC;

  -- propagate known unspent status for all outputs
  INSERT INTO esplora_known_unspent(response_id, output_id, height)
  SELECT new.response_id
       , output.id
       , chain_tip_height.height
    FROM esplora_outspend_status
    JOIN tx as funding_tx ON funding_tx.txid = esplora_outspend_status.funding_txid
    JOIN output ON output.funding_tx_id = funding_tx.id AND output.vout = esplora_outspend_status.vout
    JOIN chain_tip_height
   WHERE esplora_outspend_status.spending_txid IS NULL
     AND esplora_outspend_status.response_id = new.response_id;

  -- when full transactions are provided, mark their input & output counts as known
  -- this signifies that the immutable transaction data is fully known in the database
  -- so no fetching is required (some txs have only a txid and several
  -- inputs/outputs associated with them)
  -- TODO(consistency) constraint - in table or here? in general - enforce equality invariant in case of update to inputs, outputs, or txs
  INSERT INTO tx(txid, input_count, output_count)
  SELECT txid, input_count, output_count
    FROM esplora_tx_vin_vout_counts
   WHERE response_id = new.response_id
     AND input_count IS NOT NULL AND output_count IS NOT NULL
  ON CONFLICT(txid)
  DO UPDATE
  SET input_count = CASE
        WHEN input_count IS     NULL THEN excluded.input_count
        WHEN input_count IS NOT NULL AND input_count == excluded.input_count THEN input_count
        ELSE raise(ABORT, 'mismatched input count')
      END
    , output_count = CASE
        WHEN output_count IS     NULL THEN excluded.output_count
        WHEN output_count IS NOT NULL AND output_count == excluded.output_count THEN output_count
        ELSE raise(ABORT, 'mismatched output count')
      END;

-- FIXME - the two triggers are combined (and the raise(IGNORE) commented out
-- above) because if done separately for some reason the contiguous_bound_tx_id
-- gets set to NULL.
-- END;

-- -- TODO batch version of this trigger - insert into script (select view) on conflict update
-- CREATE TRIGGER update_script_tx_boundaries_on_fetch
-- AFTER INSERT ON esplora_response
-- WHEN new.request_path LIKE 'address/%/txs/chain%' -- TODO(mempool) TODO(reorg)
-- BEGIN

-- CREATE TRIGGER update_script_tx_boundaries_on_fetch
-- AFTER INSERT ON esplora_response_txs_cache
-- BEGIN

  --  update fetch_newest_tx_id if it's null, or falls within the current result page
  UPDATE script
     SET fetch_newest_tx_id = (SELECT coalesce(response_newest_tx_id, fetch_newest_tx_id)
                                 FROM esplora_response_address_txs_page_boundaries
                                WHERE response_id = new.response_id)
       , fetch_newest_tx_read_height = (SELECT height from chain_tip_height) -- FIXME trigger ordering. this should be set to max(coalesce(new.prior_height, chain_tip_height), implied)?
   WHERE id = (SELECT script_id
                 FROM esplora_response_address_txs_page_boundaries
                WHERE response_id = new.response_id)
     AND ( fetch_newest_tx_id IS NULL
        OR fetch_newest_tx_id IN (SELECT id
                                    FROM esplora_response_tx_ids
                                   WHERE response_id = new.response_id));

  -- update fetch_oldest_tx_id if it's null or if fetch_oldest_tx_id was used
  -- as the last_seen_tx_id in a continuation request
  UPDATE script
  SET fetch_oldest_tx_id =
  (SELECT coalesce(response_oldest_tx_id, fetch_oldest_tx_id) -- don't clear yet if null, since we compare to contiguous_bound_tx_id
                                 FROM esplora_response_address_txs_page_boundaries
                                WHERE response_id = new.response_id)
   WHERE id = (SELECT script_id
                 FROM esplora_response_address_txs_page_boundaries
                WHERE response_id = new.response_id)
     AND ( fetch_oldest_tx_id IS NULL
        OR fetch_oldest_tx_id = (SELECT last_seen_tx_id
                                   FROM esplora_response_address_txs_page_boundaries
                                  WHERE response_id = new.response_id));

  -- update contiguous_bound_tx_id when it appears in the current page of
  -- results or when this is a terminal response page (fewer than 25 txs)
  -- if this is a continuation of a a previous page, set it to
  -- fetch_newest_tx_id, otherwise newest_tx_id
  UPDATE script
     SET contiguous_bound_tx_id = (SELECT CASE
                                            WHEN fetch_oldest_tx_id == last_seen_tx_id THEN fetch_newest_tx_id
                                            ELSE coalesce(response_newest_tx_id, contiguous_bound_tx_id)
                                          END
                                     FROM script JOIN esplora_response_address_txs_page_boundaries ON script.id = script_id
                                    WHERE response_id = new.response_id)
   WHERE id = (SELECT script_id
                 FROM esplora_response_address_txs_page_boundaries
                WHERE response_id = new.response_id)
     AND ( contiguous_bound_tx_id IN (SELECT id
                                        FROM esplora_response_tx_ids
                                       WHERE response_id = new.response_id)
        OR (contiguous_bound_tx_id IS NULL
          AND (SELECT terminal
                 FROM esplora_response_address_txs_page_boundaries
                WHERE response_id = new.response_id)));

   -- reset ongoing fetch status when we've reached the top
   -- TODO unhandled edge case - when fetching suppose address X has
   -- txs [1, 2, 3, 4] paged as [1, 2, 3], [4]. first [1, 2, 3] is returned.
   -- then instead of fetching w/ last_seen_tx_id = 3, last_seen_tx_id = 2 is sent, returning [3, 4]
   -- contiguous_bound_tx_id is updated to 3. upon resuming the saved fetch
   -- sequence and fetching at 3, [4] is returned, but contiguous_bound_tx_id is
   -- already set, so it will be a noop.
   UPDATE script
     SET fetch_oldest_tx_id = NULL, fetch_newest_tx_id = NULL
     WHERE contiguous_bound_tx_id = fetch_newest_tx_id;
END;

