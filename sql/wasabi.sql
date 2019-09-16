-- the set of scripts to which coordinator fees are paid in Wasabi coinjoins
CREATE VIEW wasabi_coordinator_script AS
SELECT *
  FROM script
 WHERE address IN ('bc1qs604c7jv6amk4cxqlnvuxv26hv3e48cds4m0ew', 'bc1qa24tsgchvuxsaccp8vrnkfd85hrcpafg20kmjw');

 -- transactions which pay the wasabi coordinator
 CREATE VIEW coordinator_funding_tx AS
 SELECT tx.*
 FROM tx
 JOIN output ON tx.id = funding_tx_id
 JOIN wasabi_coordinator_script ON script_id = wasabi_coordinator_script.id;

-- transactions which have outputs that divide each other with no remainder
-- used to identify wasabi mixed outputs with multiple of base denomination
CREATE VIEW tx_even_denomination AS
  SELECT DISTINCT funding_tx_id AS id, min(a.sats, b.sats) AS sats
          FROM output AS a JOIN output AS b USING(funding_tx_id)
         WHERE a.sats != 0 AND  b.sats != 0 AND a.sats != b.sats AND ( a.sats % b.sats == 0 OR b.sats % a.sats == 0);

-- transaction counts of equivalent outputs (same script type & amount)
CREATE VIEW tx_equivalent_denomination AS
SELECT funding_tx_id AS id, script_type_id, sats, count(*) AS count
  FROM output
  JOIN script ON script_id = script.id
  JOIN tx ON funding_tx_id = tx.id
 GROUP BY funding_tx_id, script.script_type_id, sats;  -- outputs with different script types are not considered indistinguishable

-- FIXME very slow when a view onto tx_even_denomination
-- query with id = ... clause
-- if can finish in less than 1 min then acceptable for batch loading - actually does it in 15
CREATE VIEW tx_even_base_denomination AS
SELECT funding_tx_id AS id, min(a.sats, b.sats) AS sats
  FROM output AS a JOIN output AS b USING(funding_tx_id)
  WHERE a.sats != 0 AND  b.sats != 0 AND a.sats != b.sats AND ( a.sats % b.sats == 0 OR b.sats % a.sats == 0)
 GROUP BY funding_tx_id;

-- FIXME really slow
CREATE VIEW tx_equivalent_base_denomination AS
SELECT DISTINCT id, max(count) OVER win AS count, first_value(sats) OVER win AS sats
  FROM tx_equivalent_denomination
WINDOW win AS (PARTITION BY id
                   ORDER BY count DESC
                   RANGE BETWEEN UNBOUNDED PRECEDING
                     AND UNBOUNDED FOLLOWING);

-- outputs that are part of an equivalence class, and whose funding transaction
-- has at least that many inputs (TODO filter inputs less than equivalence class amount in size condition)
CREATE VIEW coinjoin_output AS
SELECT output.*, tx_equivalent_denomination.count as equivalence_class_size
  FROM output
  JOIN script ON output.script_id = script.id
  JOIN tx ON output.funding_tx_id = tx.id
  JOIN tx_equivalent_denomination ON funding_tx_id = tx_equivalent_denomination.id
   AND output.sats = tx_equivalent_denomination.sats
   AND script.script_type_id = tx_equivalent_denomination.script_type_id
 WHERE input_count >= equivalence_class_size;

-- Wasabi CoinJoin transactions are transactions that pay the coordinator and
-- have some output equivalence class of size greater than 1.
-- base_denomination is the amount in sats of the largest equivalence class
-- adjusted_base_denomination is the base denomination deducting any fee discounts, which should be very close to the base denomination
-- -- FIXME really really slow
-- instead we just select and link these separately, and do the adjustment calculation on the python side
-- CREATE VIEW wasabi_coinjoin_tx AS
-- SELECT tx.*
--      , equiv.count AS participant_count
--      , equiv.sats AS base_denomination
--      , coalesce(even.sats / CAST(round(1.0*even.sats/equiv.sats) AS INTEGER), equiv.sats) AS adjusted_base_denomination
--   FROM coordinator_funding_tx AS tx
--  CROSS JOIN tx_equivalent_base_denomination AS equiv USING(id)
--  LEFT JOIN tx_even_base_denomination AS even USING(id);

