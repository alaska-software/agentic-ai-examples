//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Tool classes for the Financial Calculator + Live Currency Conversion example.
///
/// Two tool objects are attached to a single PromptRunner:
///
///   CalculatorTool  - exact arithmetic (add/subtract/multiply/divide, percentage)
///   CurrencyTool    - live exchange rates via ExchangeRate-API (exchangerate-api.com)
///
/// The LLM decides autonomously which tools to call, in what order, and how
/// many times per question. ToolAwareSender drives the multi-round SSE loop
/// transparently; GenerateText() returns only after the LLM emits its final
/// text answer.
///
/// No separate API key is required for CurrencyTool — the service i provided 
/// by Alaska software for demonstrational purpose
/// </summary>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "..\agentic-ai-core.ch"
#include "common.ch"


// ---------------------------------------------------------------------------
// CalculatorTool
//
// Two methods:
//   Calculate( a, op, b ) - basic four-operation arithmetic; returns a number.
//   Percentage( base, pct ) - pct% of base; returns the percentage amount.
//
// Both return a plain Xbase++ number. AbstractToolClass:serializeResult()
// converts it to a JSON number string that the LLM reads as a raw numeric value.
//
// abortOnError is left at the default (.F.) so that user errors (bad operator,
// division by zero) are reported back to the LLM as an "Error: ..." tool result
// instead of aborting the entire tool-calling loop.
// ---------------------------------------------------------------------------

/// <public>
/// <one-liner>Exact arithmetic tools: four-operation calculator and percentage</one-liner>
/// <description>
/// Gives the LLM access to exact arithmetic so financial answers are never
/// approximated. The LLM calls Calculate() for basic operations and Percentage()
/// to derive a VAT amount, a budget share, or any other percent-of-base value.
/// Both methods return a plain number; the LLM incorporates it into its text reply.
/// </description>
/// <groups>tools</groups>
/// </public>
///
CLASS CalculatorTool FROM AbstractToolClass

   EXPORTED:
   CLASS METHOD onRegister()       // declare tool schema once per class
   METHOD init()
   METHOD calculate( oInput )     // { a, op, b }    -> number
   METHOD percentage( oInput )    // { base, pct }   -> number

ENDCLASS


/// <summary>
/// Declare the two arithmetic tools. Called once by InitClass() — shared
/// across all instances of CalculatorTool via CLASS VAR toolDefs.
/// </summary>
///
CLASS METHOD CalculatorTool:onRegister()

   ::addTool( "Calculate", ;
      "Perform basic arithmetic on two numbers. " + ;
      "Returns the exact numeric result. " + ;
      "Use this for any addition, subtraction, multiplication, or division.", ;
      ToolParam() ;
         :addNumber( "a",  .T., "First operand" ) ;
         :addString( "op", .T., "Operator: add, subtract, multiply, divide" ) ;
         :addNumber( "b",  .T., "Second operand" ) )

   ::addTool( "Percentage", ;
      "Calculate what pct% of base is and return that amount. " + ;
      "Example: Percentage(base=8400, pct=19) returns 1596 — the 19% portion, not the total. " + ;
      "Add the result to the base yourself if you need the gross total.", ;
      ToolParam() ;
         :addNumber( "base", .T., "The base value to apply the percentage to" ) ;
         :addNumber( "pct",  .T., "The percentage to apply, e.g. 19 for 19%%" ) )

RETURN Self


METHOD CalculatorTool:init()
   ::AbstractToolClass:init()     // abortOnError defaults to .F.
RETURN Self


/// <summary>
/// Perform basic arithmetic. Returns the numeric result, or an "Error: ..."
/// string when the operator is unknown or a division by zero is attempted.
/// </summary>
///
METHOD CalculatorTool:calculate( oInput )
   LOCAL nA  := oInput:a
   LOCAL cOp := Lower( AllTrim( oInput:op ) )
   LOCAL nB  := oInput:b

   DO CASE
   CASE cOp == "add"      ;  RETURN nA + nB
   CASE cOp == "subtract" ;  RETURN nA - nB
   CASE cOp == "multiply" ;  RETURN nA * nB
   CASE cOp == "divide"
      IF nB == 0
         RETURN "Error: division by zero"
      ENDIF
      RETURN nA / nB
   ENDCASE

RETURN "Error: unknown operator '" + cOp + "'. Use: add, subtract, multiply, divide."


/// <summary>
/// Calculate pct% of base. Returns the percentage amount (not the gross total).
/// </summary>
///
METHOD CalculatorTool:percentage( oInput )
   LOCAL nBase := oInput:base
   LOCAL nPct  := oInput:pct
RETURN ( nBase * nPct ) / 100


// ---------------------------------------------------------------------------
// CurrencyTool
//
// Two methods:
//   GetExchangeRate( fromCurrency, toCurrency )
//     -> DataObject { fromCurrency, toCurrency, rate, lastUpdated }
//
//   ConvertAmount( amount, fromCurrency, toCurrency )
//     -> DataObject { originalAmount, fromCurrency, toCurrency,
//                     rate, convertedAmount, lastUpdated }
//
// Both methods return a DataObject. SerializeResult() JSON-encodes it so the
// LLM receives all fields in one structured block — rate, result, and the
// timestamp of the last rate update all in one tool-result message.
//
// FetchUrl() is a protected helper that issues a plain HTTP GET. The
// ExchangeRate-API free tier requires no separate auth header — the key
// is part of the base URL.
// ---------------------------------------------------------------------------

/// <public>
/// <one-liner>Live exchange-rate tools: rate lookup and amount conversion</one-liner>
/// <description>
/// Gives the LLM access to live exchange rates from exchangerate-api.com.
/// GetExchangeRate() returns the current rate for any currency pair.
/// ConvertAmount() performs the conversion in one call and returns both the
/// converted amount and the rate used, so the LLM can cite them in its reply.
/// <para/>
/// The free-tier API key is embedded in apiBaseUrl; no environment variable is
/// required. All ISO 4217 currency codes supported by exchangerate-api.com work
/// as fromCurrency / toCurrency arguments (EUR, USD, GBP, CHF, JPY, …).
/// </description>
/// <groups>tools</groups>
/// </public>
///
CLASS CurrencyTool FROM AbstractToolClass

   EXPORTED:
   VAR apiBaseUrl

   CLASS METHOD onRegister()
   METHOD init()
   METHOD getExchangeRate( oInput )   // { fromCurrency, toCurrency }          -> DataObject
   METHOD convertAmount( oInput )     // { amount, fromCurrency, toCurrency }   -> DataObject

   PROTECTED:
   METHOD fetchUrl( cUrl, nStatus )   // HTTP GET helper; nStatus passed by reference

ENDCLASS


/// <summary>
/// Declare the two currency tools. Called once by InitClass().
/// </summary>
///
CLASS METHOD CurrencyTool:onRegister()

   ::addTool( "GetExchangeRate", ;
      "Get the current live exchange rate from one currency to another. " + ;
      "Returns the rate and the UTC timestamp of the last data update. " + ;
      "Use this when you need the rate but will calculate the converted amount yourself.", ;
      ToolParam() ;
         :addString( "fromCurrency", .T., "ISO 4217 source currency code, e.g. EUR, USD, GBP, CHF" ) ;
         :addString( "toCurrency",   .T., "ISO 4217 target currency code, e.g. EUR, USD, GBP, CHF" ) )

   ::addTool( "ConvertAmount", ;
      "Convert a monetary amount from one currency to another at the current live rate. " + ;
      "Returns the converted amount, the exact rate used, and the rate date in yyyymmdd format. " + ;
      "Prefer this over GetExchangeRate when you need both the rate and the converted value.", ;
      ToolParam() ;
         :addNumber( "amount",       .T., "The monetary amount to convert" ) ;
         :addString( "fromCurrency", .T., "ISO 4217 source currency code, e.g. EUR, USD, GBP, CHF" ) ;
         :addString( "toCurrency",   .T., "ISO 4217 target currency code, e.g. EUR, USD, GBP, CHF" ) )

RETURN Self


METHOD CurrencyTool:init()
   ::AbstractToolClass:init()
   ::apiBaseUrl := "https://api1.alaska-software.net"
RETURN Self


/// <summary>
/// Fetch the current exchange rate for a currency pair.
/// Calls: GET /pair/{FROM}/{TO}
/// Returns a DataObject with fromCurrency, toCurrency, rate, and lastUpdated, or an
/// "Error: ..." string when the API call fails.
/// </summary>
///
METHOD CurrencyTool:getExchangeRate( oInput )
   LOCAL cFrom    := Upper( AllTrim( oInput:fromCurrency ) )
   LOCAL cTo      := Upper( AllTrim( oInput:toCurrency   ) )
   LOCAL cUrl     := ::apiBaseUrl + "/exchangerate/" + cFrom + "/" + cTo
   LOCAL nStatus  := 0
   LOCAL cBody
   LOCAL oParsed
   LOCAL oResult

   // Short-circuit: same currency needs no API call.
   IF cFrom == cTo
      oResult                 := DataObject():New()
      oResult:fromCurrency    := cFrom
      oResult:toCurrency      := cTo
      oResult:rate            := 1
      oResult:lastUpdated     := "n/a (same currency)"
      RETURN oResult
   ENDIF

   cBody := ::fetchUrl( cUrl, @nStatus )

   IF cBody == NIL .OR. nStatus != 200
      RETURN "Error: exchange rate API returned HTTP " + AllTrim( Str( nStatus ) ) + ;
             " for " + cFrom + "/" + cTo
   ENDIF

   oParsed := Json2Var( cBody )
   IF ValType( oParsed ) != "O"
      RETURN "Error: unexpected response format from exchange rate API"
   ENDIF

   IF IsMemberVar( oParsed, "error" ) .AND. !IsNull(oParsed:Error)
      RETURN "Error: exchange rate API returned failure for " + cFrom + "/" + cTo
   ENDIF

   oResult                 := DataObject():New()
   oResult:fromCurrency    := cFrom
   oResult:toCurrency      := cTo
   oResult:rate            := oParsed:result:rate
   oResult:lastUpdated     := DToS( oParsed:result:date )
RETURN oResult


   /// <summary>
   /// Convert an amount from one currency to another at the current live rate.
   /// Calls: GET /pair/{FROM}/{TO}/{AMOUNT}
/// Returns a DataObject with originalAmount, convertedAmount, rate, and
/// lastUpdated, or an "Error: ..." string when the API call fails.
/// </summary>
///
METHOD CurrencyTool:convertAmount( oInput )
   LOCAL nAmount  := oInput:amount
   LOCAL cFrom    := Upper( AllTrim( oInput:fromCurrency ) )
   LOCAL cTo      := Upper( AllTrim( oInput:toCurrency   ) )
   LOCAL cUrl     := ::apiBaseUrl + "/exchangerate/" + cFrom + "/" + cTo
   LOCAL nStatus  := 0
   LOCAL cBody
   LOCAL oParsed
   LOCAL oResult

   // Short-circuit: same currency, nothing to convert.
   IF cFrom == cTo
      oResult                 := DataObject():New()
      oResult:originalAmount  := nAmount
      oResult:fromCurrency    := cFrom
      oResult:toCurrency      := cTo
      oResult:rate            := 1
      oResult:convertedAmount := nAmount
      oResult:lastUpdated     := "n/a (same currency)"
      RETURN oResult
   ENDIF

   cBody := ::fetchUrl( cUrl, @nStatus )

   IF cBody == NIL .OR. nStatus != 200
      RETURN "Error: exchange rate API returned HTTP " + AllTrim( Str( nStatus ) ) + ;
             " for " + cFrom + "/" + cTo
   ENDIF

   oParsed := Json2Var( cBody )
   IF ValType( oParsed ) != "O"
      RETURN "Error: unexpected response format from exchange rate API"
   ENDIF

   IF IsMemberVar( oParsed, "error" ) .AND. !IsNull(oParsed:Error)
      RETURN "Error: exchange rate API returned failure for " + cFrom + "/" + cTo
   ENDIF

   oResult                 := DataObject():New()
   oResult:originalAmount  := nAmount
   oResult:fromCurrency    := cFrom
   oResult:toCurrency      := cTo
   oResult:rate            := oParsed:result:rate
   oResult:convertedAmount := Round( nAmount * oParsed:result:rate, 4 )
   oResult:lastUpdated     := DToS( oParsed:result:date )
RETURN oResult


/// <summary>
/// Issue a plain HTTP GET to cUrl and return the response body as a string.
/// Sets nStatus (passed by reference) to the HTTP status code, or 0 on
/// connection failure. Returns NIL when the response object is absent.
/// </summary>
///
METHOD CurrencyTool:fetchUrl( cUrl, nStatus )
   LOCAL oClient   := HttpClient():New()
   LOCAL oRequest  := HttpRequestMessage():New( cUrl )
   LOCAL oResponse

   nStatus := 0
   oRequest:setMethod( "GET" )
   oResponse := oClient:send( oRequest )
   nStatus   := oClient:getStatusCode()

   IF oResponse == NIL
      RETURN NIL
   ENDIF

RETURN oResponse:getContent()


// ---------------------------------------------------------------------------
// XML config loading
//
// Sample questions are read from an XML file (calculator-tool-questions-en.config
// by default, or the German calculator-tool-questions-de.config) with the
// Xbase++ XmlSimpleParser(). Document shape:
//
//   <questions>
//     <question><internal/><text/></question>
//     ...
//   </questions>
//
// The <internal> element is ignored by the loader; it is metadata for the
// reader, describing which tool-call sequence each question is meant to
// exercise (same convention as support-triage-emails.config).
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
/// drop indentation whitespace; internal line breaks (e.g. the supplier
/// list in the comparison question) are preserved as-is.
/// </remarks>
/// <param name="oNode">parsed XML question node</param>
/// <returns>the question text (C)</returns>
///
FUNCTION NodeToQuestion( oNode )
RETURN AllTrim( oNode:text )
