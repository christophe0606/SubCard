# Editable query results: conservative implementation reference

Status: proposed design, 2026-10-18. This document specifies future behavior;
query-result editing and the analyzer described here are **not implemented**.

The [view column builder](views.md) now implements saved single-table projections
and aggregate choices, including hidden-identity handling. It does not implement
the result-write analysis or operations specified below.

## Decision and scope

Yes: SubCard can recognize a useful subset of editable SELECT results without
attempting to solve every SQL view-update problem. Use a structural proof against
the actual database schema, then generate narrowly scoped writes to one base
table. Never infer editability from the current result data, column labels, or
the apparent simplicity of the SQL text.

The input must include the query, schema constraints, and an explicit write
target. SQL alone cannot tell us whether the author intended to edit an order
or its customer when both appear in a row. For a single-table query, its table
is the default target. For a join, the view author selects the anchor table;
the initial implementation requires it to be the leftmost FROM table. This
selection does not bypass any proof requirement.

**Safety requirement:** an enabled operation must have an unambiguous mapping to
one identified base row, or to one new base row for insertion. Reject everything
outside the supported proof rules. False negatives are acceptable. No heuristic,
sampling, manual “editable” flag, or runtime absence of duplicates may promote an
unproved query to writable.

This is a guarantee of the specified rules under enforced schema constraints,
correct parsing, and controlled writes. It is not a claim that an unimplemented
analyzer, corrupt database, or arbitrary extension is infallible. Tests and
fail-closed handling are part of the implementation requirement.

“Editable” means **selected cells can update the anchor record**. It does not
mean every displayed cell is writable. Insertion is analyzed separately; deletion
and automatic multi-table writes are outside the initial feature.

## Existing SubCard foundations

The shared C++ core is the authority for both SwiftUI and GPUI. Relevant code:

- [`ERModel.cpp`](../../backend/src/ERModel.cpp) creates STRICT `user_t<ID>`
  tables, hidden `id INTEGER PRIMARY KEY AUTOINCREMENT` identities, ordinary
  fields `f<ID>`, and hidden relationship columns `r<ID>`. Proposed query writes
  treat these identities as immutable.
- An ER arrow A → B means “A has one/many B”; the physical reference is in B and
  points to A. A 1:1 adds UNIQUE to B's reference. References are nullable, so
  “one” means **at most one**, not guaranteed participation. See the
  [relationship contract](entity-relationship-canvas.md#table-relationships-2026-10-18).
- [`UserData.cpp`](../../backend/src/UserData.cpp) owns transactional user writes,
  global fake/real provenance, schema locking, and an authorizer. It currently
  forbids stored user SQL views, triggers, and virtual tables, including on open.
- [`CheckExpression.cpp`](../../backend/src/CheckExpression.cpp) validates CHECK
  expressions; it is not a SELECT parser or a cardinality analyzer.

Here, “view” means a saved SELECT definition/result model. The column builder
stores definitions in ER metadata version 6 rather than as SQLite CREATE VIEW
objects. Do not relax the
existing executable-schema restrictions merely to implement this feature.

SQLite itself treats views as read-only; INSTEAD OF triggers can supply custom
behavior, but cannot establish that the behavior is unambiguous. SubCard should
issue explicit base-table writes after its own proof, without generated triggers.
See [SQLite CREATE VIEW](https://www.sqlite.org/lang_createview.html).

## Separate the capabilities

Return a structured analysis rather than one boolean:

| Capability | Meaning |
| --- | --- |
| `update` | The result preserves anchor identity and at least one permitted field can be written. |
| `columns[i].writable` | Output ordinal i directly represents one permitted anchor field. |
| `insert` | A supported single-anchor insert form/plan exists, subject to ordinary value validation. |
| `insertRequirements` | Required inputs, relationship selectors, defaults and fixed context. |
| `delete` | Unsupported initially, even when update is supported. |
| `reasons` | Stable reason codes and useful explanations for denied capabilities. |

A supported operation can still fail for invalid values, constraints, stale
state, or failure to remain in the view. “Insert supported” never promises that
every submitted value combination is valid. An absent required input or missing
insert plan must not appear as an enabled Add Row command.

Related columns and calculated columns may coexist with writable anchor columns.
A row with no writable projected anchor field is read-only, even if identity can
be recovered. The entire query is read-only if the row-preservation proof fails.

## What must be proved

For anchor alias A with identity K, the admitted query Q must satisfy:

1. Every output row has exactly one non-null anchor identity K.
2. Each anchor identity occurs **at most once** in Q, for every valid database
   state satisfying the certified schema, not just for today's rows.
3. Each writable output ordinal maps directly to exactly one ordinary column of
   A; no inverse expression or related-record choice is needed.
4. A backend-issued row token binds that identity to this document, query,
   parameters, schema and data revision. The frontend cannot redirect the write.
5. The write and validation run atomically through the document lifecycle policy.

This is injectivity from result rows to base identities, not a requirement to
display every anchor row. WHERE and INNER JOIN may exclude anchors.

SQL SELECT normally retains duplicate *values*. For example, two people named
“Alex” can both appear in `SELECT name FROM people` and remain individually
editable through hidden identities. This is different from one person appearing
twice because a join found two related records. DISTINCT may merge the two people
and is rejected initially.

## Initial supported SQL subset

Use a small explicit grammar and typed, resolved AST (abstract syntax tree).
Admission requires complete consumption of exactly one SELECT. Unknown syntax,
unresolved identifiers, unsupported nodes and analysis limits produce read-only
results with a reason. Never strip clauses or skip unrecognized tokens.

| Construct | Initial rule |
| --- | --- |
| One ordinary SubCard ER table | Supported with certified hidden integer identity. |
| Direct columns, aliases, qualified names | Supported; bind output by ordinal and source by stable IDs. |
| `*` / `alias.*` | Expand from the certified schema; hide internal keys in presentation and keep them nonwritable. |
| Scalar expressions/constants | Display-only, using an explicit pure scalar expression/function allowlist. |
| WHERE | Supported pure expressions over admitted aliases and typed bound parameters; no subqueries. |
| ORDER BY | Supported admitted expressions or resolved output references; never used as identity. |
| INNER JOIN / LEFT JOIN | Supported only by the lookup proof below. |
| LIMIT / OFFSET | Updates may be supported; insertion disabled initially. Hidden identity tie-breakers make ordering deterministic. |
| DISTINCT, GROUP BY, HAVING, aggregates | Entire query read-only, including an aggregate without GROUP BY. |
| Window functions | Entire query read-only initially, even where row identity could survive. |
| UNION / UNION ALL / INTERSECT / EXCEPT | Entire query read-only. UNION ALL can repeat anchor identities. |
| CTEs, nested SELECTs, derived tables, stored SQL views | Entire query read-only initially. |
| RIGHT / FULL / CROSS / comma / NATURAL joins, USING | Entire query read-only initially. |
| Repeated physical table, including self joins | Entire query read-only initially; alias-sensitive extension needs separate proof. |
| Virtual/table-valued sources, attached/temp databases, system tables | Entire query read-only. |
| Volatile/context-sensitive functions or unknown extensions | Entire query read-only. |

Expression support must enumerate operators and functions, not just prohibit
known aggregates. For example, `lower(name)` can be display-only; `random()` and
date/time expressions depending on “now” are outside the initial grammar.
Check all expression positions, including ORDER BY, for forbidden constructs.
Reuse audited scalar policies where appropriate, but the CHECK tokenizer alone
does not satisfy this parser requirement.

Limits/offsets are frozen nonnegative integer values in the plan. For admitted
paginated queries, append anchor identity to ORDER BY as a final tie-breaker
(and use identity ordering if none was supplied). This produces the canonical
query shown and executed by SubCard. Never silently rewrite arbitrary SQL whose
semantics the analyzer does not understand. Editing a sort field can move the row
off the current page; the strict membership rule below then rejects that edit.

## Proving joins cannot multiply anchor rows

Analyze the written, left-associated join chain. Start with one row per anchor
identity. For each new alias R, require an ON clause made exclusively of ANDed
direct-column equalities (`=` or `==`). Each equality must pair a column of R
with a column of an already admitted alias. Reject OR, expressions, constants,
null-safe comparisons, extra predicates and ambiguous join nesting initially.

Those equalities must bind **all components of one enforced unique key of R**.
Require ordinary full keys: the primary key or a nonpartial UNIQUE index over
real columns, with SQLite's uniqueness enforcement active. A normal index is
insufficient. No partial or expression index
qualifies initially; a subset of a composite unique key is insufficient.

The initial implementation accepts only STRICT INTEGER columns on both sides
of these equalities and built-in BINARY collations. This deliberately covers
SubCard's generated integer relationship keys and IDs. Matching UNIQUE text keys,
legacy noninteger references and other types remain read-only until the separate
comparison proof is implemented. Do not treat a column's declared type in a
non-STRICT table as a guarantee of stored type.

An INNER lookup contributes zero or one R row; a LEFT lookup contributes exactly
one result, including its null-extended case. Neither can multiply the previous
rows. Repeat for every join. WHERE only removes rows and projection/ordering
preserve multiplicity in the admitted grammar. This gives the induction proof
that anchor identity remains unique.

Chained lookups are allowed: a newly joined table can be used to look up another
unique key. A nullable intermediate alias still contributes at most one match.
Every edge must pass independently; one multiplying edge makes the whole result
read-only, even when a later filter happens to remove today's duplicates.

### Relationship direction matters

For `child.parent_id = parent.id`:

- Anchor **child**, look up parent: safe even for a many-to-one relationship.
  Many children may share a parent, but each child finds at most one parent.
- Anchor **parent**, look up child: safe only if `child.parent_id` has an eligible
  UNIQUE constraint. A foreign key or ordinary index on it is insufficient.
- LEFT JOIN to a unique optional child: anchor fields remain writable when the
  child is absent; there is no child record to edit or create implicitly.

Thus the requested one-to-one enrichment joins are covered. Many-to-one
enrichment is also covered **for anchor fields**. Related fields remain read-only
in both cases. Editing a customer's name through an orders grid could change
what many orders display; that is a separate related-record command.

### SQLite comparison traps

An eligible uniqueness constraint must constrain the same equality relation used
by the join. Two important counterexamples:

```sql
-- k is UNIQUE under BINARY, but the query compares under NOCASE.
CREATE TABLE lookup(k TEXT UNIQUE COLLATE BINARY) STRICT;
INSERT INTO lookup VALUES ('A'), ('a');
SELECT * FROM lookup WHERE k = 'a' COLLATE NOCASE; -- two matches

-- INTEGER affinity in the join converts distinct TEXT values to numbers.
CREATE TABLE codes(k TEXT UNIQUE) STRICT;
CREATE TABLE numbers(k INTEGER) STRICT;
INSERT INTO codes VALUES ('1'), ('01');
INSERT INTO numbers VALUES (1);
SELECT * FROM numbers n JOIN codes c ON n.k = c.k; -- two matches
```

Also, nullable UNIQUE keys can contain several NULLs. Ordinary `=` cannot match
NULL, so such a key can prove at most one match for the admitted integer joins.
`IS` / `IS NOT DISTINCT FROM` can match several NULLs and must not use that proof.

These restrictions follow from SQLite's [comparison and collation
rules](https://www.sqlite.org/datatype3.html#comparison_expressions) and
[unique-index NULL semantics](https://www.sqlite.org/lang_createindex.html#unique_indexes).
Any future text/composite-type extension must prove the effective affinity and
collation component by component, including operand order and explicit COLLATE.

## Field mapping and hidden identity

Only a bare, resolved reference to an ordinary anchor field is writable. Aliasing
it does not change the mapping. `price * quantity`, `CAST(...)`, `COALESCE(...)`,
literals, generated columns, IDs and related-table fields are display-only.
Do not guess inverses, even for expressions that seem reversible.

If the same anchor field appears several times, all occurrences share one draft
value and one physical assignment. Reject conflicting values supplied through
duplicate projections; never let the last assignment silently win. Duplicate
column labels are allowed for display but cannot identify a write destination.

For admitted queries only, generate a canonical internal SELECT carrying the
anchor `id` as private row metadata even if the user did not select it. Carry
identity alongside each result row, never via visible text or list position.
Injecting an identity into DISTINCT/GROUP BY would change semantics; these queries
were already rejected and must never be “repaired” this way.

Issue an opaque row token containing or referencing:

```text
document instance + query/plan ID + schema fingerprint
bound parameter values/types + data revision + anchor ID
```

Resolve it in the owning document backend. IDs from two documents may be equal;
tokens and plans are not interchangeable. Use SQLite 64-bit integer identity
without conversion through floating point, especially across JSON/FFI boundaries.
AUTOINCREMENT does not replace document identity or stale-token protection.

## Insert analysis: a separate single-table contract

Adding a row means creating **one anchor record**, then deriving the displayed
row by running the query. Never insert into all joined tables, infer a new related
record from its displayed name, or invert calculated outputs.

Build an explicit insert plan:

1. Generate the anchor identity internally; it is never user supplied.
2. Map direct writable fields to anchor columns. Additional required anchor inputs
   may be offered in a separately configured insert form, even if not projected.
3. For every omitted anchor column, record whether it is nullable, has an allowed
   database default, or is supplied by explicit fixed context/relationship input.
   An omitted NOT NULL field without a valid supplier disables insertion. CHECK,
   UNIQUE and foreign-key constraints still require validation by SQLite.
4. Distinguish omitted values from explicit NULL: omission permits a database
   default; NULL does not request that default. Reject unsupported default
   expressions and generated-column behavior in the initial schema profile.
5. Hidden outgoing references can use a relationship picker resolving an existing
   record to its key. A fixed context such as “new order for this customer” binds
   that key explicitly. A related label is never a key or a creation request.
6. Do not synthesize values from arbitrary WHERE predicates. A future compiler
   may supply recognized equality context, but must represent it explicitly and
   reject conflicts with submitted fields. `status = 'open'` does not by itself
   authorize guessing other hidden required values.
7. Disable insertion for LIMIT/OFFSET queries initially. Disable it where an INNER
   join would require creating/relinking another table to make the new anchor
   visible. For example, inserting a new parent cannot also create its unique
   required child through a parent-to-child INNER JOIN. Optional LEFT enrichment
   does not require such a child.
8. Run the actual candidate INSERT, recover its identity, and require exactly one
   matching row in the full view before committing. If any validation fails,
   roll back both the candidate and lifecycle metadata.

No general static solver for CHECK predicates or insert satisfiability is needed.
An insert plan certifies the write destination and input sources; candidate
validation certifies the particular new row. Impossible or incomplete structural
plans are disabled before the user starts entering a row.

An empty result can still support insertion: the proof uses the schema and query,
not an existing row. Conversely, a simple projection can support updates but lack
enough inputs for insertion.

## Membership policy and transactional write protocol

Choose strict view membership for the initial feature: an updated or inserted
anchor must still appear **exactly once in the same canonical view**. This is an
application-level check-option policy, not a SQLite view feature. For example,
an edit changing `status` from “open” to “closed” in an open-orders view is rejected
with an explanation. Allowing rows to disappear after edits can be a separately
specified later policy; never do it accidentally.

For each row update or insert:

1. Resolve the backend plan and token in the focused document's own state. Recheck
   capabilities, provenance/mode policy, schema fingerprint and parameter context.
   Do not trust frontend writable flags, submitted table/column names or SQL.
2. Serialize the entire operation with the document's other reads/writes and
   establish a transaction/savepoint. Check the token's data revision inside this
   boundary. Initially, any intervening user-data write invalidates an update
   token; report stale data and refresh. This is conservative but avoids lost
   updates, changes to joined records and delete/reinsert identity confusion.
3. For update, confirm the anchor currently occurs once in the original canonical
   query. Generate `UPDATE <anchor> SET <approved columns>=?... WHERE id=?` with
   bound values and a unique identity predicate. Never match by projected values,
   page index, sort order, related labels or a join predicate.
4. Require exactly one direct affected anchor row. For insert, generate one
   parameterized `INSERT`, recover the newly generated ID (for example with
   RETURNING), and require one inserted anchor. Handle no-op drafts explicitly;
   do not depend on change counts to detect value differences.
5. Re-run the **full canonical query with its frozen parameters**, carrying hidden
   identity. Count the candidate ID after all filtering, sorting and pagination;
   require one occurrence. Use an outer filter on the full result or inspect that
   result; pushing `WHERE id=?` inside a LIMIT changes membership and is wrong.
   A runtime count is an additional check, never a replacement for static proof.
6. Validate all immediate/deferred constraints and commit through the lifecycle
   boundary. First successful real data must latch the schema lock; fake and real
   data must never mix. Publish dirty state, new data revision and undo history
   only after success. Failure restores all rows, metadata and cached state.
7. Refresh the result and issue new tokens; recompute derived/related values.
   Refresh other views of the same document affected by the write.

The existing SQL-batch write API cannot simply be called, allowed to commit, and
then followed by view validation. Future implementation must add an internal
typed transactional command with bound statements and precommit validation, or
refactor its internals to expose the same atomic policy boundary. Preserve the
authorizer and controlled function set. Keep triggers, identity updates,
multi-table writes and UPDATE cascades outside this initial write profile.

SQLite [transactions](https://www.sqlite.org/lang_transaction.html) provide the
atomic boundary. Its [direct change count](https://www.sqlite.org/c3ref/changes.html)
does not account for trigger or foreign-key side effects, so it cannot alone
prove “only this row changed.” The no-trigger profile, immutable identities and
permitted-column policy are necessary parts of that claim. Verify
[foreign-key enforcement](https://www.sqlite.org/foreignkeys.html) on the
connection; validate deferred failures before publishing success.

## Analyzer and backend architecture

Recommended pipeline in the shared C++ backend:

```text
Saved SELECT + explicit anchor + insert form/context
    -> strict parser -> resolved typed AST
    -> certified physical schema snapshot
    -> supported-grammar and join-cardinality proof
    -> output lineage + update/insert plans + denial reasons
    -> canonical read query + private row tokens
    -> typed transactional write -> validation -> refresh
```

Schema certification must compare ER metadata to the physical database, not trust
a diagram's “1:1” label. Inspect table properties, columns, keys and indexes with
`table_list`, `table_xinfo`, `index_list`, `index_xinfo`, and `foreign_key_list`,
plus relevant schema definitions for unsupported objects. Check returned metadata
completely; missing/unknown metadata denies writes. These are backend-owned reads,
not permission to expose arbitrary PRAGMA execution to document queries. See
[SQLite schema PRAGMAs](https://www.sqlite.org/pragma.html).

Reject write certification if the connection has disabled required integrity
checks, uses unsupported functions/collations, or the schema contains triggers,
generated/virtual columns or unsupported update side effects. Do not attempt to
certify a database whose integrity/relationship checks failed on open.

Initially certify generated ER schemas only. Legacy/raw schemas not matching the
profile can still be read but must not silently inherit editability. For example,
an ordinary SQLite PRIMARY KEY declaration is not always equivalent to a non-null
integer row identity; stay with SubCard's verified integer key profile. See
[SQLite primary keys](https://www.sqlite.org/lang_createtable.html#the_primary_key).

Parse in portable C++ using a deliberately limited, fully consuming grammar, or
adopt an audited Apache-compatible parser with explicit SQLite-dialect support.
No parser dependency is chosen by this design. SQLite must also prepare the
canonical statement successfully under a read-only authorizer; parser acceptance
does not replace actual SQLite validation. Conversely, SQLite accepting syntax
does not admit it to the writable grammar. Differential tests must check that
the accepted AST and canonical SQL have the intended SQLite semantics.

SQLite has no public SELECT AST/cardinality proof API. Do not depend on its
private parser structs, bytecode or EXPLAIN plan shapes. The optional
[`sqlite3_column_*_name` metadata APIs](https://www.sqlite.org/c3ref/column_database_name.html)
can cross-check direct-column origins, but do not prove row uniqueness or
distinguish all alias roles. They require `SQLITE_ENABLE_COLUMN_METADATA`, which
the present SwiftPM, Cargo and test configurations do not enable. They are
optional checks, not a prerequisite or a substitute for parsing.

Likewise, [`sqlite3_stmt_readonly`](https://www.sqlite.org/c3ref/stmt_readonly.html)
describes whether a statement writes the database; it does not describe whether
SELECT results can be mapped back to safe writes.

A plan contains the analyzed AST, stable table/field IDs, target identity,
per-join key evidence, output-ordinal mappings, insert suppliers and query/schema
fingerprints. Cache it per document instance. Invalidate on schema/model changes,
query/anchor changes, insert-form changes, parameter changes, reopen/replacement,
or changes to function/collation/connection semantics. Use an application-owned
schema generation/fingerprint; a user-schema version number alone is insufficient.
Treat persisted analysis results as untrusted cache and recompute on open.

Use bounded parser depth, SQL size and join count; exceeded limits mean read-only.
An LLM may suggest a query or explanation, but must never supply the proof or
the backend's authorization decision.

## Worked examples

The names below are readable stand-ins for SubCard's stable physical identifiers.
Assume generated STRICT tables and integer relationship columns unless stated.

| Query shape | Updates | Inserts |
| --- | --- | --- |
| `SELECT name, email FROM person` | Direct fields writable; hidden person ID identifies each row. | Supported if all required omitted inputs have suppliers. |
| `SELECT name FROM person WHERE active = 1` | Name writable, subject to membership. | Needs explicit active context/input and any other required fields. |
| `SELECT quantity, quantity * price AS total FROM line` | Quantity writable; total read-only. | Quantity/price suppliers needed; total is never an input mapping. |
| `SELECT o.note, c.name FROM orders o JOIN customer c ON o.customer_id = c.id` | With orders as anchor, note writable and customer name read-only. | Needs existing-customer selection/context and required order fields. |
| `SELECT p.name, x.bio FROM person p LEFT JOIN profile x ON x.person_id = p.id` | Person name writable if profile.person_id is UNIQUE; bio read-only. | May create only a person; an absent profile stays absent. |
| Same query using INNER JOIN | Same update proof. | Disabled if adding a person would also require creating/relinking a profile. |
| `SELECT p.name, o.note FROM person p JOIN orders o ON o.person_id = p.id` | Read-only for person anchor when orders.person_id is nonunique. | Disabled. Rewrite around orders to edit orders. |
| `SELECT customer_id, SUM(amount) FROM orders GROUP BY customer_id` | Read-only. | Disabled. |
| `SELECT DISTINCT name FROM person` | Read-only, even when names currently happen to be unique. | Disabled. |
| `SELECT name FROM person ORDER BY name LIMIT 20` | Supported with canonical identity tie-breaker and post-write membership validation. | Disabled initially. |

## Reasons and presentation

Keep reason codes independent of localized text. Suggested initial codes:

```text
UNSUPPORTED_QUERY_SHAPE          NO_CERTIFIED_IDENTITY
ANCHOR_REQUIRED                 ANCHOR_NOT_LEFTMOST
JOIN_MULTIPLICITY_UNPROVEN       JOIN_COMPARISON_UNSUPPORTED
SCHEMA_NOT_CERTIFIED            NO_WRITABLE_PROJECTED_FIELDS
RELATED_COLUMN                  COMPUTED_COLUMN
INSERT_INPUT_MISSING            INSERT_REQUIRES_RELATED_WRITE
INSERT_PAGINATION_UNSUPPORTED   ROW_OUTSIDE_VIEW
STALE_RESULT                    CONSTRAINT_FAILED
```

Explain “Several orders may match this person; this result cannot edit people”
instead of just “Not editable.” An unsupported case means “editability cannot be
proved by this version,” not that SQL makes editing fundamentally impossible.

Both frontends consume identical capabilities, field mappings and reasons.
Desktop commands belong in the global menus with focused-document validation;
iPhone uses its native compact controls. Do not add a second desktop command
strip above the canvas. A related field can offer a separately named “Open related
record” action in later work, never an implicit write to another table. No new
frontend controls or menus are implemented by this document.

## Implementation sequence and acceptance criteria

1. Define the certified ER schema profile, SELECT grammar and versioned analysis
   result. Implement parser/resolver rejection tests before enabling writes.
2. Support single-table projection/filter/order updates with hidden identity and
   typed transactions. Exercise actual rollback, provenance and stale-token cases.
3. Add integer-key INNER/LEFT lookup chains with explicit anchor selection and
   per-column writability. Extend only when each rule has a proof and countertests.
4. Add single-anchor insert forms, context, required-input analysis and membership
   validation. Keep unsupported insert plans disabled even for updatable results.
5. Connect the common C ABI to SwiftUI and GPUI, then document/validate desktop and
   iPhone presentation separately. Physical-device compilation only for iPhone;
   no simulator installation. Leave multi-target editing and broader SQL for later.

Minimum future test matrix:

| Area | Required cases |
| --- | --- |
| Projection/identity | Hidden ID; aliases; quoted/Unicode names; equal visible values with distinct IDs; duplicate projected fields; duplicate labels; identity above 2^53; wildcard expansion. |
| Positive joins | Child→parent many-to-one; UNIQUE reverse 1:1; INNER/LEFT; missing related row; nullable references; several independent lookups; chained optional lookups; complete composite integer unique key. |
| Negative joins | Nonunique FK; normal index; incomplete composite key; partial/expression index; OR; CAST; collation mismatch; mixed affinity; null-safe equality; repeated table/self join; later edge causing multiplication. |
| Query rejection | Aggregation with/without GROUP BY; bare aggregate columns; HAVING; DISTINCT; window; UNION ALL; CTE; nested/stored views; subquery anywhere; volatile functions; unsupported join; unconsumed SQL. |
| Insert planning | Required omitted field; nullable/default omission versus NULL; explicit fixed context; relationship selector; empty result; computed-only projection; related label never creates a record; missing INNER-related row; pagination. |
| Write validation | CHECK/NOT NULL/UNIQUE/FK errors; deferred FK failure; zero/multiple visible identities; filter changes; page-boundary sorting; derived-value refresh; single physical assignment for repeated fields. |
| Atomicity/lifecycle | Failed candidates leave rows, dirty state, history and provenance unchanged; first real insert locks schema; fake/real isolation; failed insert does not latch a new lock. |
| Freshness/isolation | Another write changes anchor or lookup; delete/reinsert; query/parameter changes; schema/index change; reopen; two documents share IDs; focused window changes; token or field-map tampering. |
| Parser consistency | Strings/comments containing SQL keywords; nested parentheses; name shadowing attempts; malformed/trailing statements; depth limits; compare accepted AST/canonical execution with bundled SQLite. |

For generated valid schemas and admitted queries, property-based tests should
construct adversarial data, including duplicates and NULLs, and assert that every
reported anchor identity occurs at most once. For every successful mutation,
assert exactly one intended anchor changed, related rows remained unchanged, and
the candidate remains visible once. Such tests supplement the proof; no finite
sample establishes editability for arbitrary future data.

## Validation of this design document

Reviewed against the current generated schema, authorizer and write lifecycle.
Targeted local probes linked to SubCard's bundled **SQLite 3.54.1** confirmed:

- Child→parent lookup preserves child count; the reverse nonunique join multiplies
  a parent even with foreign keys enabled.
- Equal projected values retain distinct rows; DISTINCT merges them.
- Nullable UNIQUE accepts multiple NULLs; `=` gives no NULL matches while `IS`
  can match several rows.
- Both the BINARY/NOCASE and INTEGER/TEXT examples above produce two matches.
- An inserted anchor can be absent from an INNER JOIN; rolling back the candidate
  removes it completely.

These ten probe assertions verify SQLite premises, not an analyzer implementation
or frontend behavior. No production code, dependency or schema format was changed.
