//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// ComplaintHandlerAgent - customer complaint and return handler.
/// The flow is declared in onRegister(); the framework builds and drives
/// the state machine.
/// </summary>
///
/// <remarks>
/// This file supplies the agent class.
///
/// Flow:
///      +--[ AssessDefect    ]--+  (LLM - defect likelihood)
///      |                       |
/// ---->+--[ ScoreCustomer   ]--+--> decide --> draft (terminal)
///      |                       |
///      +--[ CheckEntitlement]--+  (LLM - policy entitlement)
///      ^                       ^
///   parallel                  join
///
/// All three branches read from the same blackboard snapshot (the incoming
/// ComplaintSource). ScoreCustomer is a deterministic ledger lookup; the
/// other two are LLM calls. All three run concurrently. Decide() combines
/// the three results into a resolution using a deterministic rule set.
/// DraftReply() writes the customer-facing email.
/// </remarks>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "..\agentic-ai-core.ch"
#include "common.ch"

CLASS ComplaintHandlerAgent FROM AbstractAgent
   EXPORTED:
   VAR customerLedger
   VAR returnPolicy

   METHOD init( oCustomerLedger, oReturnPolicy, oLLMOptions )
   METHOD onRegister()

   // Parallel branch action methods
   METHOD assessDefect( oCtx )      // LLM: defect likelihood assessment
   METHOD scoreCustomer( oCtx )     // Deterministic: customer ledger lookup
   METHOD checkEntitlement( oCtx )  // LLM: policy entitlement check

   // Sequential action methods
   METHOD decide( oCtx )            // Deterministic: combine branch results
   METHOD draftReply( oCtx )        // LLM: write the customer-facing email

ENDCLASS


METHOD ComplaintHandlerAgent:init( oCustomerLedger, oReturnPolicy, oLLMOptions )
   DEFAULT oLLMOptions TO LLMOptions():withModel( AnthropicModels():CLAUDE_HAIKU_4_5 ) ;
                                        :withTemperature( 0 )
   ::AbstractAgent:init()
   ::customerLedger := oCustomerLedger
   ::returnPolicy   := oReturnPolicy
   ::withDefaultLLM( oLLMOptions )
RETURN Self


/// <summary>
/// onRegister() - the single place that owns the flow definition.
/// </summary>
/// <remarks>
/// The parallel state runs all three branches at the same time. Each branch
/// receives a snapshot clone of the blackboard (containing the ComplaintSource
/// under "source") and writes its result to a dedicated output key. After all
/// three complete, the engine merges their outputs onto the main blackboard
/// and continues to "decide".
/// </remarks>
///
METHOD ComplaintHandlerAgent:onRegister()

   ::addParallel( "assess", ;
      { { "AssessDefect",    "defect"       }, ;
        { "ScoreCustomer",   "customer"     }, ;
        { "CheckEntitlement","entitlement"  } }, ;
      "decide" )

   ::addState( "decide", "Decide", "defect, customer, entitlement", "decision" ) ;
      :onGuard( NIL, "draft" )

   ::addState( "draft", "DraftReply", "source, decision", "reply" ) ;
      :terminal()

RETURN Self


// ---------------------------------------------------------------------------
// Parallel branch action methods
// ---------------------------------------------------------------------------

/// <summary>
/// Reads the complaint text and assesses how likely the described problem is a
/// genuine product defect. Uses a fast/cheap model since this is a simple
/// classification task.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>DefectAssessment</returns>
///
METHOD ComplaintHandlerAgent:assessDefect( oCtx )
   LOCAL oSource := oCtx:get( "source" )
   LOCAL oRunner
   LOCAL oResult
   LOCAL oErr

   oRunner := oCtx:ai() ;
              :withPromptContributor( ComplaintPersonas():assessor() ) ;
              :withPromptContributor( Instruction():create( ;
                 "Assess how likely the described problem is a genuine product defect." + CRLF + ;
                 "Return these fields:" + CRLF + ;
                 "  likelihood : exactly one of: high, medium, low" + CRLF + ;
                 "  reason     : one sentence explaining the assessment" + CRLF + ;
                 "Use 'high' for clear manufacturing or shipping defects." + CRLF + ;
                 "Use 'medium' for plausible but unverified defects." + CRLF + ;
                 "Use 'low' for preference changes, misuse, or vague descriptions." ) )

   oResult := oRunner:createObject( ;
                 "Assess the defect likelihood for this complaint:" + CRLF + oSource:getText(), ;
                 "DefectAssessment" )

   IF oResult == NIL
      oErr := ErrorNew()
      oErr:description := "AssessDefect: " + oRunner:getLastError()
      Break( oErr )
   ENDIF

RETURN oResult


/// <summary>
/// Looks up the customer in the ledger by ID. Returns a default "new" profile
/// when the ID is not found. No LLM call - demonstrates that parallel branches
/// can mix AI and non-AI work.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>CustomerProfile</returns>
///
METHOD ComplaintHandlerAgent:scoreCustomer( oCtx )
   LOCAL oSource   := oCtx:get( "source" )
   LOCAL oCustomer := ::customerLedger:findById( oSource:customerId )

   IF oCustomer == NIL
      RETURN CustomerProfile():New( oSource:customerId, "Unknown customer", "new", 0, 0 )
   ENDIF

RETURN oCustomer


/// <summary>
/// Reads the complaint against the full returns policy and determines what the
/// customer is entitled to. Uses a stronger model than AssessDefect because
/// accurate policy interpretation requires more careful reasoning.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>EntitlementCheck</returns>
///
METHOD ComplaintHandlerAgent:checkEntitlement( oCtx )
   LOCAL oSource := oCtx:get( "source" )
   LOCAL oRunner
   LOCAL oResult
   LOCAL oErr

   oRunner := oCtx:ai() ;
              :withLLM( LLMOptions():withModel( AnthropicModels():CLAUDE_SONNET_4_6 ):withTemperature( 0 ) ) ;
              :withPromptContributor( ComplaintPersonas():policyAdvisor() ) ;
              :withPromptContributor( Instruction():create( ;
                 "Apply the following returns policy to the customer complaint." + CRLF + ;
                 "POLICY:" + CRLF + ::returnPolicy:getPolicyText() + CRLF + CRLF + ;
                 "Return these fields:" + CRLF + ;
                 "  recommended : exactly one of: refund, replace, investigate, decline" + CRLF + ;
                 "  basis       : one sentence citing which policy clause applies" ) )

   oResult := oRunner:createObject( ;
                 "Determine the policy entitlement for this complaint:" + CRLF + oSource:getText(), ;
                 "EntitlementCheck" )

   IF oResult == NIL
      oErr := ErrorNew()
      oErr:description := "CheckEntitlement: " + oRunner:getLastError()
      Break( oErr )
   ENDIF

RETURN oResult


// ---------------------------------------------------------------------------
// Sequential action methods
// ---------------------------------------------------------------------------

/// <summary>
/// Combines the three parallel branch results into a single resolution using a
/// deterministic rule set. The rule order is: policy first, then defect
/// likelihood, then customer tier as a tiebreaker. No LLM is involved so the
/// decision is consistent, auditable, and fast.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>ResolutionDecision</returns>
///
METHOD ComplaintHandlerAgent:decide( oCtx )
   LOCAL oDefect      := oCtx:get( "defect" )
   LOCAL oCustomer    := oCtx:get( "customer" )
   LOCAL oEntitlement := oCtx:get( "entitlement" )
   LOCAL cRecommended
   LOCAL cLikelihood
   LOCAL cTier
   LOCAL cAction
   LOCAL cRationale
   LOCAL cPriority

   cRecommended := Lower( AllTrim( If( oEntitlement:recommended == NIL, "investigate", oEntitlement:recommended ) ) )
   cLikelihood  := Lower( AllTrim( If( oDefect:likelihood      == NIL, "low",         oDefect:likelihood      ) ) )
   cTier        := Lower( AllTrim( If( oCustomer:tier          == NIL, "new",         oCustomer:tier          ) ) )

   DO CASE

   // Policy declines and customer is not a VIP - respect the policy
   CASE cRecommended == "decline" .AND. cTier != "vip"
      cAction    := "decline"
      cRationale := oEntitlement:basis

   // Policy declines but customer is a VIP - escalate for manual review
   CASE cRecommended == "decline" .AND. cTier == "vip"
      cAction    := "investigate"
      cRationale := "Outside standard policy window; escalated for VIP customer review."

   // Clear defect confirmed - follow the policy recommendation
   CASE cLikelihood == "high"
      cAction    := cRecommended
      cRationale := "Defect confirmed: " + oDefect:reason

   // Probable defect and VIP customer - give benefit of the doubt
   CASE cLikelihood == "medium" .AND. cTier == "vip"
      cAction    := cRecommended
      cRationale := "Probable defect; VIP customer receives benefit of the doubt."

   // Probable defect but non-VIP - request more information before committing
   CASE cLikelihood == "medium"
      cAction    := "investigate"
      cRationale := "Defect description inconclusive; additional information requested."

   // Low defect likelihood (preference return, etc.) - follow policy as-is
   OTHERWISE
      cAction    := cRecommended
      cRationale := oEntitlement:basis

   ENDCASE

   cPriority := If( cTier == "vip" .OR. cLikelihood == "high", "urgent", "normal" )

RETURN ResolutionDecision():New( cAction, cRationale, cPriority )


/// <summary>
/// Writes the customer-facing email based on the resolution decision. The prompt
/// includes the original complaint for context and the decision for tone and
/// content. The action field of the decision drives what is communicated.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>ComplaintReply</returns>
///
METHOD ComplaintHandlerAgent:draftReply( oCtx )
   LOCAL oSource   := oCtx:get( "source" )
   LOCAL oDecision := oCtx:get( "decision" )
   LOCAL oRunner
   LOCAL oResult
   LOCAL oErr

   oRunner := oCtx:ai() ;
              :withLLM( LLMOptions():withModel( AnthropicModels():CLAUDE_SONNET_4_6 ) ) ;
              :withPromptContributor( ComplaintPersonas():drafter() ) ;
              :withPromptContributor( Instruction():create( ;
                 "Write a customer-facing email based on the following resolution." + CRLF + ;
                 "Decision : " + oDecision:Action + CRLF + ;
                 "Rationale: " + oDecision:rationale + CRLF + CRLF + ;
                 "Return these fields:" + CRLF + ;
                 "  subject : a clear and professional email subject line" + CRLF + ;
                 "  body    : the full email body, 80 to 120 words, no placeholders, signed 'Customer Service'" ) )

   oResult := oRunner:createObject( ;
                 "Draft a reply to this complaint:" + CRLF + oSource:getText(), ;
                 "ComplaintReply" )

   IF oResult == NIL
      oErr := ErrorNew()
      oErr:description := "DraftReply: " + oRunner:getLastError()
      Break( oErr )
   ENDIF

RETURN oResult
