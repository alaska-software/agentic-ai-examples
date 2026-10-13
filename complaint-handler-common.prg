//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Shared domain layer for the ComplaintHandlerAgent example
/// (LOB use case - Customer Complaint and Return Handler).
///
/// complaint-handler-agent.prg supplies the agent class; complaint-handler-main.prg
/// has Main(). This file provides the domain types, the demo customer ledger,
/// the return policy, XML loading, and the personas.
/// </summary>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "common.ch"

#define CRLF Chr(13)+Chr(10)

// ---------------------------------------------------------------------------
// Domain / blackboard types
//
// ComplaintSource is the run input. The three parallel branch outputs
// (DefectAssessment, CustomerProfile, EntitlementCheck) land on the
// blackboard after the parallel state completes. Decide() produces a
// ResolutionDecision; DraftReply() produces a ComplaintReply.
//
// Every type that the LLM populates derives from AbstractCard so that
// PromptRunner:createObject() can bind the JSON response by member name.
// ---------------------------------------------------------------------------

/// <summary>
/// ComplaintSource - the raw incoming complaint handed to the agent by the driver.
/// </summary>
///
CLASS ComplaintSource FROM AbstractCard
   EXPORTED:
   VAR customerId
   VAR orderNumber
   VAR channel
   VAR subject
   VAR body
   VAR productName
   METHOD init( cCustomerId, cOrderNumber, cChannel, cSubject, cBody, cProductName )
   METHOD getText()
ENDCLASS

METHOD ComplaintSource:init( cCustomerId, cOrderNumber, cChannel, cSubject, cBody, cProductName )
   ::customerId  := If( cCustomerId  == NIL, "", cCustomerId  )
   ::orderNumber := If( cOrderNumber == NIL, "", cOrderNumber )
   ::channel     := If( cChannel     == NIL, "", cChannel     )
   ::subject     := If( cSubject     == NIL, "", cSubject     )
   ::body        := If( cBody        == NIL, "", cBody        )
   ::productName := If( cProductName == NIL, "", cProductName )
RETURN Self

/// <summary>
/// Flatten the complaint into a single text block for prompts.
/// </summary>
///
METHOD ComplaintSource:getText()
   LOCAL cText := ""
   IF !Empty( ::channel )
      cText += "Channel:  " + ::channel + CRLF
   ENDIF
   cText += "Subject:  " + ::subject + CRLF
   IF !Empty( ::productName )
      cText += "Product:  " + ::productName + CRLF
   ENDIF
   cText += "Message:" + CRLF + ::body
RETURN cText


/// <summary>
/// DefectAssessment - LLM branch output: how likely is the reported defect genuine?
/// </summary>
///
CLASS DefectAssessment FROM AbstractCard
   EXPORTED:
   VAR likelihood  // "high" | "medium" | "low"
   VAR reason      // one-sentence explanation
   METHOD init( cLikelihood, cReason )
ENDCLASS

METHOD DefectAssessment:init( cLikelihood, cReason )
   ::likelihood := If( cLikelihood == NIL, "low", cLikelihood )
   ::reason     := If( cReason     == NIL, "",    cReason     )
RETURN Self


/// <summary>
/// CustomerProfile - deterministic branch output: customer record from the ledger.
/// </summary>
///
CLASS CustomerProfile FROM AbstractCard
   EXPORTED:
   VAR customerId
   VAR name
   VAR tier        // "vip" | "regular" | "new"
   VAR orderCount
   VAR totalSpend
   METHOD init( cCustomerId, cName, cTier, nOrderCount, nTotalSpend )
ENDCLASS

METHOD CustomerProfile:init( cCustomerId, cName, cTier, nOrderCount, nTotalSpend )
   ::customerId := If( cCustomerId == NIL, "",        cCustomerId )
   ::Name       := If( cName       == NIL, "Unknown", cName       )
   ::tier       := If( cTier       == NIL, "new",     cTier       )
   ::orderCount := If( nOrderCount == NIL, 0,         nOrderCount )
   ::totalSpend := If( nTotalSpend == NIL, 0,         nTotalSpend )
RETURN Self


/// <summary>
/// EntitlementCheck - LLM branch output: what the customer is entitled to under policy.
/// </summary>
///
CLASS EntitlementCheck FROM AbstractCard
   EXPORTED:
   VAR recommended  // "refund" | "replace" | "investigate" | "decline"
   VAR basis        // one sentence citing the applicable policy clause
   METHOD init( cRecommended, cBasis )
ENDCLASS

METHOD EntitlementCheck:init( cRecommended, cBasis )
   ::recommended := If( cRecommended == NIL, "investigate", cRecommended )
   ::basis       := If( cBasis       == NIL, "",            cBasis       )
RETURN Self


/// <summary>
/// ResolutionDecision - deterministic join output: the chosen action and its rationale.
/// </summary>
///
CLASS ResolutionDecision FROM AbstractCard
   EXPORTED:
   VAR action     // "refund" | "replace" | "investigate" | "decline"
   VAR rationale  // short internal reason (not sent to the customer)
   VAR priority   // "urgent" | "normal"
   METHOD init( cAction, cRationale, cPriority )
ENDCLASS

METHOD ResolutionDecision:init( cAction, cRationale, cPriority )
   ::Action    := If( cAction    == NIL, "investigate", cAction    )
   ::rationale := If( cRationale == NIL, "",            cRationale )
   ::priority  := If( cPriority  == NIL, "normal",      cPriority  )
RETURN Self


/// <summary>
/// ComplaintReply - LLM terminal output: the drafted customer-facing email.
/// </summary>
///
CLASS ComplaintReply FROM AbstractCard
   EXPORTED:
   VAR subject
   VAR body
   METHOD init( cSubject, cBody )
ENDCLASS

METHOD ComplaintReply:init( cSubject, cBody )
   ::subject := If( cSubject == NIL, "", cSubject )
   ::body    := If( cBody    == NIL, "", cBody    )
RETURN Self


// ---------------------------------------------------------------------------
// Data providers
//
// CustomerLedger: base interface + in-memory demo implementation.
// ReturnPolicy: provides the policy text injected into the entitlement prompt.
// A production implementation would back these against DBF tables or a REST API.
// ---------------------------------------------------------------------------

CLASS CustomerLedger
   EXPORTED:
   METHOD findById( cId )
ENDCLASS

METHOD CustomerLedger:findById( cId )
   UNUSED( cId )
RETURN NIL


CLASS DemoCustomerLedger FROM CustomerLedger
   EXPORTED:
   VAR rows
   METHOD init()
   METHOD findById( cId )
ENDCLASS

METHOD DemoCustomerLedger:init()
   ::rows := { ;
      CustomerProfile():New( "CUST-001", "Weber GmbH",   "vip",     52, 12400.00 ), ;
      CustomerProfile():New( "CUST-002", "T. Kleinmann", "new",      3,   180.00 ), ;
      CustomerProfile():New( "CUST-003", "Bauer & Co.",  "regular", 18,  3200.00 )  ;
   }
RETURN Self

METHOD DemoCustomerLedger:findById( cId )
   LOCAL nPos := AScan( ::rows, {|o| o:customerId == cId } )
   IF nPos > 0
      RETURN ::rows[nPos]
   ENDIF
RETURN NIL


CLASS ReturnPolicy
   EXPORTED:
   METHOD getPolicyText()
ENDCLASS

METHOD ReturnPolicy:getPolicyText()
RETURN "RETURNS AND COMPLAINTS POLICY" + CRLF + ;
   "1. Standard returns: accepted within 30 days of delivery, item unused in original packaging." + CRLF + ;
   "2. VIP customers (10 or more prior orders): extended 60-day return window." + CRLF + ;
   "3. Defective products: accepted within 90 days; a description of the defect is required." + CRLF + ;
   "4. Wrong item delivered: full refund or replacement at no cost, no time limit applies." + CRLF + ;
   "5. Duplicate charges: refunded in full within 2 business days upon verification." + CRLF + ;
   "6. Refund method: same as original payment, processed within 5 business days." + CRLF + ;
   "7. Replacement offered as an alternative to a refund when stock is available." + CRLF + ;
   "8. Custom or personalised orders: non-returnable unless defective." + CRLF + ;
   "9. Requests outside these conditions require manager approval before any commitment."


// ---------------------------------------------------------------------------
// XML config loading
//
// Complaints are read from an XML file (complaint-handler-samples-en.config
// by default, or the German complaint-handler-samples-de.config) with the
// Xbase++ XmlSimpleParser(). Document shape:
//
//   <complaints>
//     <complaint>
//       <internal/>
//       <customerId/><orderNumber/><channel/><subject/><body/><productName/>
//     </complaint>
//     ...
//   </complaints>
//
// The <internal> element is ignored by the loader; it is metadata for the
// reader, describing what each sample complaint is meant to exercise (same
// convention as support-triage-emails.config).
// ---------------------------------------------------------------------------

/// <summary>
/// Load complaints from an XML config file.
/// </summary>
/// <remarks>
/// Returns an empty array (and prints why) when the file is missing/empty or
/// the XML is malformed - XmlSimpleParser() raises an "XML" subsystem error on
/// bad input, caught here so a typo in the config does not crash the run.
/// </remarks>
/// <param name="cConfigFile">path to the XML config file</param>
/// <returns>array of ComplaintSource</returns>
///
FUNCTION LoadComplaints( cConfigFile )
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
      // Document root is <complaints>; <complaint> children are read by name.
      // A single child parses to one node, several to an array - normalise
      // to an array so the caller can always iterate.
      oXml   := XmlSimpleParser( cXml )
      aNodes := oXml:complaints:complaint

      IF ValType( aNodes ) == "O"
         aNodes := { aNodes }
      ENDIF

      FOR nI := 1 TO Len( aNodes )
         AAdd( aOut, NodeToComplaint( aNodes[nI] ) )
      NEXT
   RECOVER USING oError
      ? "Failed to parse " + cConfigFile + ":", oError:description
      aOut := {}
   END SEQUENCE

RETURN aOut


/// <summary>
/// Build a ComplaintSource from an XML complaint node.
/// </summary>
/// <param name="oNode">parsed XML complaint node</param>
/// <returns>ComplaintSource</returns>
///
FUNCTION NodeToComplaint( oNode )
RETURN ComplaintSource():New( ;
   AllTrim( IIF( ValType( oNode:customerId  ) == "C", oNode:customerId,  "" ) ), ;
   AllTrim( IIF( ValType( oNode:orderNumber ) == "C", oNode:orderNumber, "" ) ), ;
   AllTrim( IIF( ValType( oNode:channel     ) == "C", oNode:channel,     "" ) ), ;
   AllTrim( IIF( ValType( oNode:subject     ) == "C", oNode:subject,     "" ) ), ;
   AllTrim( IIF( ValType( oNode:body        ) == "C", oNode:body,        "" ) ), ;
   AllTrim( IIF( ValType( oNode:productName ) == "C", oNode:productName, "" ) ) )


// ---------------------------------------------------------------------------
// Personas
// ---------------------------------------------------------------------------

CLASS ComplaintPersonas
   EXPORTED:
   CLASS METHOD assessor()
   CLASS METHOD policyAdvisor()
   CLASS METHOD drafter()
ENDCLASS

/// <summary>
/// Persona for the defect assessment branch.
/// </summary>
///
CLASS METHOD ComplaintPersonas:assessor()
RETURN RoleGoalBackstory():create( ;
   "Product quality assessor",                                                             ;
   "Evaluate complaint descriptions to determine how likely the reported problem is a genuine product defect", ;
   "Ten years in returns processing; distinguishes manufacturing defects from user error, preference changes, and exaggeration" )

/// <summary>
/// Persona for the policy entitlement branch.
/// </summary>
///
CLASS METHOD ComplaintPersonas:policyAdvisor()
RETURN RoleGoalBackstory():create( ;
   "Returns policy specialist",                                                            ;
   "Determine what the customer is entitled to under the company returns and complaints policy", ;
   "Precise and consistent; applies policy rules fairly regardless of how the customer frames the request" )

/// <summary>
/// Persona for the draft reply step.
/// </summary>
///
CLASS METHOD ComplaintPersonas:drafter()
RETURN RoleGoalBackstory():create( ;
   "Customer service writer",                                                              ;
   "Write professional and empathetic complaint resolution emails on behalf of the business", ;
   "Clear and concise; never overpromises; always explains the concrete next step to the customer" )
