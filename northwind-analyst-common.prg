//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Shared domain layer for the Northwind Business Analyst Agent example.
/// </summary>
///
/// <remarks>
/// Provides:
///   QueryResult                - stores one SQL result set for display
///   NorthwindQueryTool         - AbstractToolClass with the ExecuteQuery tool
///   NorthwindPersonas          - analyst persona factory
///   NorthwindSchemaContributor - injects the Northwind schema into the system prompt
/// </remarks>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "common.ch"
#include "dac.ch"

#define CRLF Chr(13)+Chr(10)


// ---------------------------------------------------------------------------
// QueryResult — stores one SQL result set for later display.
// Internal type; not derived from AbstractCard.
// ---------------------------------------------------------------------------

CLASS QueryResult
   EXPORTED:
   VAR title       // display heading (from tool input or "Query Result")
   VAR sql         // the SQL that was executed (original, before LIMIT injection)
   VAR columns     // array of column-name strings
   VAR rows        // array of arrays — max 10 rows; each inner array = one row
   VAR totalRows   // number of rows collected after the LIMIT cap

   METHOD init()
ENDCLASS

METHOD QueryResult:init()
   ::title     := "Query Result"
   ::Sql       := ""
   ::columns   := {}
   ::rows      := {}
   ::totalRows := 0
RETURN Self


// ---------------------------------------------------------------------------
// NorthwindQueryTool — exposes a single ExecuteQuery tool to the LLM.
//
// Design:
//   - Only SELECT statements are accepted (security gate).
//   - Results are capped at 10 rows: LIMIT 10 is appended when absent.
//   - Each call stores a QueryResult in ::results so Main() can display
//     tables independently from the LLM-generated text answer.
//   - abortOnError = .F.: SQL errors are reported to the LLM as a tool
//     error message, giving it a chance to correct and retry the query.
//   - ::oSession keeps the DacSession alive; DacSqlStatement picks up the
//     active session automatically.
// ---------------------------------------------------------------------------

CLASS NorthwindQueryTool FROM AbstractToolClass
   EXPORTED:
   VAR oSession    // DacSession reference — kept alive to prevent GC disconnect
   VAR results     // array of QueryResult; reset by Main() before each question

   CLASS METHOD onRegister()
   METHOD init( oSession )
   METHOD executeQuery( oInput )   // { sql, title? } -> JSON string or "Error: ..."

   PROTECTED:
   METHOD runQuery( cSql )         // -> QueryResult or "Error: ..."

ENDCLASS


CLASS METHOD NorthwindQueryTool:onRegister()

   ::addTool( "ExecuteQuery", ;
      "Execute a SQL SELECT statement against the Northwind PostgreSQL database. " + ;
      "Use this tool for every data lookup — never estimate or recall values from memory. " + ;
      "Results are automatically limited to 10 rows; do not add a LIMIT clause yourself. " + ;
      "Only SELECT statements are accepted; any other SQL verb is rejected with an error. " + ;
      "Provide a short, descriptive title for the result table.", ;
      ToolParam() ;
         :addString( "sql",   .T., "A valid PostgreSQL SELECT statement (no LIMIT clause required)" ) ;
         :addString( "title", .F., "Short display heading for this result, e.g. 'Top 5 Products by Revenue'" ) )

RETURN Self


METHOD NorthwindQueryTool:init( oSession )
   ::AbstractToolClass:init()     // abortOnError = .F. (SQL errors fed back to LLM)
   ::oSession := oSession
   ::results  := {}
RETURN Self


/// <summary>
/// Validate, execute, and accumulate one SQL SELECT or CTE.
/// Returns compact JSON to the LLM (columns + rows + totalRows).
/// Also appends a QueryResult to ::results for display by Main().
/// </summary>
///
METHOD NorthwindQueryTool:executeQuery( oInput )
   LOCAL cSql
   LOCAL cTitle
   LOCAL oResult
   LOCAL oOut

   cSql   := oInput:Sql
   cTitle := "Query Result"
   IF IsMemberVar( oInput, "title" ) .AND. !Empty( oInput:title )
      cTitle := oInput:title
   ENDIF

   // Strip all leading whitespace including CR, LF, TAB.
   // AllTrim() only removes ASCII 32 (space); JSON-embedded newlines (ASCII 10/13)
   // are NOT removed by AllTrim() and cause the SELECT guard to fail.
   DO WHILE Len( cSql ) > 0 .AND. Asc( Left( cSql, 1 ) ) <= 32
      cSql := SubStr( cSql, 2 )
   ENDDO
   // Strip trailing whitespace the same way
   DO WHILE Len( cSql ) > 0 .AND. Asc( Right( cSql, 1 ) ) <= 32
      cSql := Left( cSql, Len( cSql ) - 1 )
   ENDDO

   // Security gate: allow SELECT statements and CTEs (WITH ... SELECT ...).
   // Both are read-only; any other verb (INSERT, UPDATE, DELETE, DROP) is rejected.
   IF Upper( Left( cSql, 6 ) ) != "SELECT" .AND. Upper( Left( cSql, 4 ) ) != "WITH"
      RETURN "Error: only SELECT statements and CTEs (WITH...SELECT) are allowed. " + ;
             "Rewrite your query starting with SELECT or WITH."
   ENDIF

   // Enforce max 10 rows: append LIMIT when not already present in SQL
   IF At( "LIMIT", Upper( cSql ) ) == 0
      IF cSql[-1]==";"
        cSql[-1] := " "
      ENDIF
      cSql += " LIMIT 10"
   ENDIF

   oResult := ::runQuery( cSql )
   IF ValType( oResult ) == "C"
      RETURN oResult    // "Error: ..." propagated as tool error to the LLM
   ENDIF

   oResult:title := cTitle
   AAdd( ::results, oResult )

   // Build compact JSON for the LLM (used for its text answer)
   oOut           := DataObject():New()
   oOut:title     := oResult:title
   oOut:columns   := oResult:columns
   oOut:rows      := oResult:rows
   oOut:totalRows := oResult:totalRows

RETURN Var2Json( oOut )


/// <summary>
/// Execute cSql via DacSqlStatement and collect the result set into a QueryResult.
/// Returns the populated QueryResult on success, or "Error: ..." on failure.
/// </summary>
///
METHOD NorthwindQueryTool:runQuery( cSql )
   LOCAL oResult
   LOCAL oStmt
   LOCAL aData := {}
   LOCAL nFields
   LOCAL nF
   LOCAL aRow
   LOCAL cbOld
   LOCAL oE

   oResult     := QueryResult():New()
   oResult:Sql := cSql

   oE    := NIL
   cbOld := ErrorBlock( {|oErr| Break( oErr )} )

   BEGIN SEQUENCE

      oStmt := DacSqlStatement():fromChar( cSql )
      oStmt:build():query( USQL_RESULT_WORKAREA, @aData )

      // Collect column names from the open workarea
      nFields := fcount()
      FOR nF := 1 TO nFields
         AAdd( oResult:columns, fieldname( nF ) )
      NEXT

      // Collect rows (max 10 enforced by LIMIT in the SQL)
      DO WHILE !EOF()
         aRow := {}
         FOR nF := 1 TO nFields
            AAdd( aRow, fieldget( nF ) )
         NEXT
         AAdd( oResult:rows, aRow )
         oResult:totalRows++
         SKIP 1
      ENDDO

      CLOSE

   RECOVER USING oE
      ErrorBlock( cbOld )
      RETURN "Error: " + oE:description
   END SEQUENCE

   ErrorBlock( cbOld )

RETURN oResult


// ---------------------------------------------------------------------------
// NorthwindPersonas — prompt contributor factories
// ---------------------------------------------------------------------------

CLASS NorthwindPersonas
   EXPORTED:
   CLASS METHOD analyst()
ENDCLASS

CLASS METHOD NorthwindPersonas:analyst()
RETURN RoleGoalBackstory():create( ;
   "Business intelligence analyst for Northwind Traders", ;
   "Answer data questions accurately by querying the database; " + ;
   "always state key numbers explicitly; summarise findings in plain business language", ;
   "Expert in PostgreSQL, relational data analysis, and translating query results " + ;
   "into clear, actionable business insights without reproducing raw table data in text" )


// ---------------------------------------------------------------------------
// NorthwindSchemaContributor — injects the Northwind schema once into the
// system prompt so the LLM knows table and column names before writing SQL.
//
// A static string constant is used — no DB round-trip needed at startup.
// The revenue calculation formula is included because it is non-obvious.
// ---------------------------------------------------------------------------

CLASS NorthwindSchemaContributor FROM PromptContributor
   EXPORTED:
   METHOD init()
   METHOD contribution()
ENDCLASS

METHOD NorthwindSchemaContributor:init()
   ::PromptContributor:init()
   ::Role := "NorthwindSchema"
RETURN Self

METHOD NorthwindSchemaContributor:contribution()
   LOCAL cSchema

   // IMPORTANT: column names are confirmed from information_schema.columns.
   // This Northwind install uses lowercase names WITHOUT underscores (e.g.
   // "orderid" not "order_id", "unitprice" not "unit_price").
   cSchema  := "=== Northwind PostgreSQL Schema ===" + CRLF
   cSchema  += "IMPORTANT: all column names are lowercase with NO underscores." + CRLF
   cSchema  += "TABLE customers    (customerid VARCHAR(5), companyname VARCHAR(40), " + ;
               "contactname VARCHAR(30), city VARCHAR(15), region VARCHAR(15), country VARCHAR(15))" + CRLF
   cSchema  += "TABLE employees    (employeeid INT, lastname VARCHAR(20), " + ;
               "firstname VARCHAR(10), title VARCHAR(30), reportsto INT)" + CRLF
   cSchema  += "TABLE categories   (categoryid INT, categoryname VARCHAR(15), description TEXT)" + CRLF
   cSchema  += "TABLE suppliers    (supplierid INT, companyname VARCHAR(40), country VARCHAR(15))" + CRLF
   cSchema  += "TABLE shippers     (shipperid INT, companyname VARCHAR(40))" + CRLF
   cSchema  += "TABLE products     (productid INT, productname VARCHAR(40), " + ;
               "supplierid INT, categoryid INT, unitprice DECIMAL, " + ;
               "unitsinstock SMALLINT, discontinued INT)" + CRLF
   cSchema  += "TABLE orders       (orderid INT, customerid VARCHAR(5), employeeid INT, " + ;
               "orderdate DATE, shippeddate DATE, shipvia INT, freight DECIMAL, shipcountry VARCHAR(15))" + CRLF
   cSchema  += "TABLE order_details(orderid INT, productid INT, " + ;
               "unitprice DECIMAL, quantity SMALLINT, discount REAL)" + CRLF
   cSchema  += "-- Revenue = od.unitprice * od.quantity * (1 - od.discount)" + CRLF
   cSchema  += "-- Key joins:" + CRLF
   cSchema  += "--   orders.customerid        = customers.customerid" + CRLF
   cSchema  += "--   orders.employeeid        = employees.employeeid" + CRLF
   cSchema  += "--   orders.shipvia           = shippers.shipperid" + CRLF
   cSchema  += "--   order_details.orderid    = orders.orderid" + CRLF
   cSchema  += "--   order_details.productid  = products.productid" + CRLF
   cSchema  += "--   products.categoryid      = categories.categoryid" + CRLF
   cSchema  += "--   products.supplierid      = suppliers.supplierid"

   RETURN cSchema


   // ---------------------------------------------------------------------------
   // XML config loading
   //
   // Sample business questions are read from an XML file
   // (northwind-analyst-questions-en.config by default, or the German
   // northwind-analyst-questions-de.config) with the Xbase++ XmlSimpleParser().
   // Document shape:
   //
   //   <questions>
   //     <question><internal/><text/></question>
   //     ...
   //   </questions>
   //
   // The <internal> element is ignored by the loader; it is metadata for the
   // reader, describing which SQL pattern each question is meant to exercise
   // (same convention as support-triage-emails.config).
   // ---------------------------------------------------------------------------

   /// <summary>
   /// Read the XML config and turn each <question> element into a plain prompt
   /// string ready for PromptRunner:generateText().
   /// </summary>
   /// <remarks>
   /// Returns an empty array (and prints why) when the file is missing/empty or
   /// the XML is malformed - XmlSimpleParser() raises an "XML" subsystem error on
   /// bad input, caught here so a typo in the config does not crash the run.
   /// </remarks>
   /// <param name="cConfigFile">path to the XML config file</param>
   /// <returns>array of question text (C)</returns>
   ///
   FUNCTION LoadQuestions( cConfigFile )
   LOCAL cXml := MemoRead( cConfigFile )
   LOCAL oXml
   LOCAL aNodes
   LOCAL aOut := {}
   LOCAL nI
   LOCAL oError

   IF Empty( cXml )
      ? "Config file not found or empty:", cConfigFile
      RETURN aOut
   ENDIF

   BEGIN SEQUENCE
      // Document root is <questions>; <question> children are read by name. A
      // single child parses to one node, several to an array - normalise to
      // an array so the caller can always iterate.
      oXml   := XmlSimpleParser( cXml )
      aNodes := oXml:questions:question

      IF ValType( aNodes ) == "O"
         aNodes := { aNodes }
      ENDIF

      FOR nI := 1 TO Len( aNodes )
         AAdd( aOut, NodeToQuestion( aNodes[nI] ) )
      NEXT
   RECOVER USING oError
      ? "Failed to parse " + cConfigFile + ":", oError:description
      aOut := {}
   END SEQUENCE

   RETURN aOut


   /// <summary>
   /// Build the prompt text from an XML question node.
   /// </summary>
   /// <remarks>
   /// <text> is read as a member (XmlSimpleParser idiom) and AllTrim()-ed to
   /// drop indentation whitespace.
   /// </remarks>
   /// <param name="oNode">parsed XML question node</param>
   /// <returns>the question text (C)</returns>
   ///
   FUNCTION NodeToQuestion( oNode )
   RETURN AllTrim( oNode:text )
