//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// SupportTriageAgent - agent style implementation of LOB use case 1
/// (Customer Support Triage). The flow is declared in onRegister(); the
/// framework builds and drives the state machine.
/// </summary>
///
/// <remarks>
/// The use-case doc frames triage around a "Supervisor" planner. AgenticAI
/// implements that knowledge-work-then-commit pattern with an AUTHORED state
/// machine plus a deterministic escalation gate.
///
/// Flow:
///      classify ---------> sentiment
///                            |  \
///       IsHighRisk == .F. -> |   \-> IsHighRisk == .T. -> escalate (terminal)
///                            v
///                          draft ---------> route (terminal)
///
/// Default LLM: CLAUDE_SONNET_4_6 with temperature 0 (set once in Init).
/// States that use a different model override via :withLLM() on the runner.
/// </remarks>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "common.ch"

#define CRLF Chr(13)+Chr(10)

CLASS SupportTriageAgent FROM AbstractAgent
   EXPORTED:
   VAR knowledgeBase
   VAR escalationThreshold

   METHOD init( oKnowledgeBase, nThreshold )
   METHOD onRegister()                          // called by framework before first run

   // Action methods - take the context, read/write the blackboard
   METHOD classifyTicket( oCtx )
   METHOD assessSentiment( oCtx )
   METHOD draftFirstResponse( oCtx )
   METHOD routeToQueue( oCtx )
   METHOD escalate( oCtx )

   // Guard method - pure boolean
   METHOD isHighRisk( oCtx )

   ENDCLASS


METHOD SupportTriageAgent:init( oKnowledgeBase, nThreshold )
   DEFAULT nThreshold TO -0.5
   ::AbstractAgent:init()
   ::knowledgeBase       := oKnowledgeBase
   ::escalationThreshold := nThreshold
   ::withDefaultLLM( LLMOptions():withModel( AnthropicModels():CLAUDE_SONNET_4_6 ):withTemperature( 0 ) )
RETURN Self


/// <summary>
/// onRegister() - the single place that owns the flow definition.
/// </summary>
///
METHOD SupportTriageAgent:onRegister()

   ::addState( "classify", "ClassifyTicket", "message", "classification" ) ;
      :onGuard( NIL, "sentiment" )

   ::addState( "sentiment", "AssessSentiment", "message", "sentiment" ) ;
      :onGuard( "IsHighRisk", "escalate" ) ;
      :onGuard( NIL,          "draft"    )

   ::addState( "draft", "DraftFirstResponse", "classification", "draft" ) ;
      :onGuard( NIL, "route" )

   ::addState( "route", "RouteToQueue", "classification", "assignment" ) ;
      :terminal()

   ::addState( "escalate", "Escalate", "classification, sentiment", "escalation" ) ;
      :terminal()

RETURN Self


/// <summary>
/// Classify the inbound message into type, urgency, and summary.
/// Uses the agent default LLM (SONNET, temp 0) — no :withLLM() override needed.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>TicketClassification</returns>
///
METHOD SupportTriageAgent:classifyTicket( oCtx )
   LOCAL oMessage := oCtx:get( "message" )
   LOCAL oRunner
   LOCAL oResult
   LOCAL oErr

   oRunner := oCtx:ai() ;
              :withPromptContributor( SupportPersonas():classifier() ) ;
              :withPromptContributor( Instruction():create( ;
                 "Classify each ticket into exactly these fields:" + CRLF + ;
                 "  type:    one of billing | technical | account | general" + CRLF + ;
                 "  urgency: one of low | normal | high | critical" + CRLF + ;
                 "  summary: one short sentence describing the issue" + CRLF + ;
                 "Use 'critical' only for outages, security, or legal/financial harm." ) )

   oResult := oRunner:createObject( ;
                 "Classify this support ticket:" + CRLF + oMessage:getText(), ;
                 "TicketClassification" )

   IF oResult == NIL
      oErr := ErrorNew()
      oErr:description := oRunner:getLastError()
      Break( oErr )
   ENDIF
RETURN oResult


/// <summary>
/// Assess the customer sentiment of the inbound message.
/// Overrides the default LLM with HAIKU (faster, cheaper for classification).
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>SentimentScore</returns>
///
METHOD SupportTriageAgent:assessSentiment( oCtx )
   LOCAL oMessage := oCtx:get( "message" )
   LOCAL oRunner
   LOCAL oResult
   LOCAL oErr

   oRunner := oCtx:ai() ;
              :withLLM( LLMOptions():withModel( AnthropicModels():CLAUDE_HAIKU_4_5 ):withTemperature( 0 ) ) ;
              :withPromptContributor( SupportPersonas():sentimentAnalyst() ) ;
              :withPromptContributor( Instruction():create( ;
                 "Return these fields:" + CRLF + ;
                 "  label:     one of positive | neutral | negative" + CRLF + ;
                 "  score:     a number from -1 (very negative) to 1 (very positive)" + CRLF + ;
                 "  rationale: one short sentence justifying the score" + CRLF + ;
                 "The score must be a raw JSON number, not a string." ) )

   oResult := oRunner:createObject( ;
                 "Assess the customer sentiment of this support ticket:" + CRLF + oMessage:getText(), ;
                 "SentimentScore" )

   IF oResult == NIL
      oErr := ErrorNew()
      oErr:description := oRunner:getLastError()
      Break( oErr )
   ENDIF
RETURN oResult


/// <summary>
/// Draft a first-response email for a human agent to review.
/// Uses the agent default LLM (SONNET, temp 0).
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>DraftReply</returns>
///
METHOD SupportTriageAgent:draftFirstResponse( oCtx )
   LOCAL oClassification := oCtx:get( "classification" )
   LOCAL oMessage        := oCtx:get( "message" )
   LOCAL oRunner
   LOCAL cBody
   LOCAL oErr

   oRunner := oCtx:ai() ;
              :withPromptContributor( SupportPersonas():drafter() ) ;
              :withPromptContributor( KnowledgeBaseContributor():New( oClassification:type, ::knowledgeBase ) )

   cBody := oRunner:generateText( "Draft a concise, friendly first-response reply to this customer message:" + ;
                                  CRLF + oMessage:getText() )

   IF cBody == NIL
      oErr := ErrorNew()
      oErr:description := oRunner:getLastError()
      Break( oErr )
   ENDIF

RETURN DraftReply():New( cBody )


/// <summary>
/// Map the ticket classification to a support queue and priority tier.
/// Pure deterministic routing — no LLM call.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>QueueAssignment</returns>
///
METHOD SupportTriageAgent:routeToQueue( oCtx )
   LOCAL oClassification := oCtx:get( "classification" )
   LOCAL cType           := Lower( If( oClassification:type == NIL, "", oClassification:type ) )
   LOCAL cUrgency        := Lower( If( oClassification:urgency == NIL, "", oClassification:urgency ) )
   LOCAL cQueue
   LOCAL cPriority

   DO CASE
   CASE cType == "billing"
      cQueue := "billing-support"
   CASE cType == "technical"
      cQueue := "tech-support"
   CASE cType == "account"
      cQueue := "account-management"
   OTHERWISE
      cQueue := "general-support"
   ENDCASE

   DO CASE
   CASE cUrgency == "critical"
      cPriority := "P1"
   CASE cUrgency == "high"
      cPriority := "P2"
   OTHERWISE
      cPriority := "P3"
   ENDCASE

RETURN QueueAssignment():New( cQueue, cPriority )


/// <summary>
/// Summarise why a senior agent is needed, then stop (terminal).
/// Overrides the default LLM with HAIKU.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>EscalationSummary</returns>
///
METHOD SupportTriageAgent:escalate( oCtx )
   LOCAL oClassification := oCtx:get( "classification" )
   LOCAL oSentiment      := oCtx:get( "sentiment" )
   LOCAL oMessage        := oCtx:get( "message" )
   LOCAL oRunner
   LOCAL cSummary
   LOCAL oErr

   oRunner := oCtx:ai() ;
              :withLLM( LLMOptions():withModel( AnthropicModels():CLAUDE_HAIKU_4_5 ) ) ;
              :withPromptContributor( SupportPersonas():escalator() )

   cSummary := oRunner:generateText( "In two sentences, summarise why this ticket needs a senior agent. " + ;
                                     "Type: " + AllTrim( If( oClassification:type == NIL, "?", oClassification:type ) ) + ;
                                     ", urgency: " + AllTrim( If( oClassification:urgency == NIL, "?", oClassification:urgency ) ) + ;
                                     ", sentiment: " + AllTrim( If( oSentiment:label == NIL, "?", oSentiment:label ) ) + "." + ;
                                     CRLF + oMessage:getText() )

   IF cSummary == NIL
      oErr := ErrorNew()
      oErr:description := oRunner:getLastError()
      Break( oErr )
   ENDIF

RETURN EscalationSummary():New( oClassification:type, cSummary, "senior-support" )


/// <summary>
/// Return .T. when the ticket should be escalated to a senior agent.
/// </summary>
/// <param name="oCtx">agent execution context</param>
/// <returns>.T. when the ticket is high-risk</returns>
///
METHOD SupportTriageAgent:isHighRisk( oCtx )
   LOCAL oSentiment := oCtx:get( "sentiment" )
   LOCAL oClass     := oCtx:get( "classification" )
   LOCAL nScore
   LOCAL cUrgency

   DO CASE
   CASE ValType( oSentiment:score ) == "N"
      nScore := oSentiment:score
   CASE ValType( oSentiment:score ) == "C"
      nScore := Val( oSentiment:score )
   OTHERWISE
      nScore := 0
   ENDCASE

   cUrgency := Lower( If( oClass == NIL .OR. oClass:urgency == NIL, "", oClass:urgency ) )

RETURN nScore <= ::escalationThreshold .OR. cUrgency == "critical"
