//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Shared domain layer + helpers for the SupportTriageAgent example
/// (LOB use case 1 - Customer Support Triage).
///
/// support-triage-agent.prg supplies the agent class; support-triage-main.prg has
/// Main(). This file provides the domain/blackboard types and a demo knowledge
/// base.
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
// Every type the LLM populates derives from AbstractCard so that
// PromptRunner:createObject() can bind a parsed JSON reply onto it by member
// name. Init() bodies are plain, NIL-safe assignments: the framework
// instantiates these with no arguments while building the JSON schema hint.
// ---------------------------------------------------------------------------

/// <summary>
/// InboundMessage - the raw ticket handed to the agent (the run input).
/// </summary>
///
CLASS InboundMessage FROM AbstractCard
   EXPORTED:
   VAR subject
   VAR body
   VAR channel
   METHOD init( cSubject, cBody, cChannel )
   METHOD getText()
ENDCLASS

METHOD InboundMessage:init( cSubject, cBody, cChannel )
   ::subject := cSubject
   ::body    := cBody
   ::channel := cChannel
RETURN Self

/// <summary>
/// Flatten the ticket into a single block of text for the prompt.
/// </summary>
///
METHOD InboundMessage:getText()
   LOCAL cText := ""
   IF !Empty( ::channel )
      cText += "Channel: " + ::channel + CRLF
   ENDIF
   IF !Empty( ::subject )
      cText += "Subject: " + ::subject + CRLF
   ENDIF
   cText += "Body: " + If( ::body == NIL, "", ::body )
RETURN cText


/// <summary>
/// TicketClassification - what kind of ticket, and how urgent.
/// </summary>
/// <remarks>
/// type    : billing | technical | account | general
/// urgency : low | normal | high | critical
/// </remarks>
///
CLASS TicketClassification FROM AbstractCard
   EXPORTED:
   VAR type
   VAR urgency
   VAR summary
   METHOD init( cType, cUrgency, cSummary )
ENDCLASS

METHOD TicketClassification:init( cType, cUrgency, cSummary )
   ::type    := cType
   ::urgency := cUrgency
   ::summary := cSummary
RETURN Self


/// <summary>
/// SentimentScore - customer mood.
/// </summary>
/// <remarks>
/// label : positive | neutral | negative
/// score : numeric in [-1, 1] (-1 = very negative)
/// </remarks>
///
CLASS SentimentScore FROM AbstractCard
   EXPORTED:
   VAR label
   VAR score
   VAR rationale
   METHOD init( cLabel, nScore, cRationale )
ENDCLASS

METHOD SentimentScore:init( cLabel, nScore, cRationale )
   ::label     := cLabel
   ::score     := nScore
   ::rationale := cRationale
RETURN Self


/// <summary>
/// DraftReply - the suggested first response for a human agent to review.
/// </summary>
///
CLASS DraftReply FROM AbstractCard
   EXPORTED:
   VAR body
   METHOD init( cBody )
ENDCLASS

METHOD draftReply:init( cBody )
   ::body := cBody
RETURN Self


/// <summary>
/// QueueAssignment - the deterministic routing decision.
/// </summary>
///
CLASS QueueAssignment FROM AbstractCard
   EXPORTED:
   VAR queue
   VAR priority
   METHOD init( cQueue, cPriority )
ENDCLASS

METHOD QueueAssignment:init( cQueue, cPriority )
   ::queue    := cQueue
   ::priority := cPriority
RETURN Self


/// <summary>
/// EscalationSummary - produced when the ticket trips the escalation gate.
/// </summary>
///
CLASS EscalationSummary FROM AbstractCard
   EXPORTED:
   VAR category
   VAR summary
   VAR suggestedOwner
   METHOD init( cCategory, cSummary, cOwner )
ENDCLASS

METHOD EscalationSummary:init( cCategory, cSummary, cOwner )
   ::category       := cCategory
   ::summary        := cSummary
   ::suggestedOwner := cOwner
RETURN Self


// ---------------------------------------------------------------------------
// Knowledge base provider
//
// Mirrors DataModelProvider in the SQL example: a small seam the draft step
// reads from to ground the suggested reply. A real implementation would back
// this with a vector store / RAG retriever.
// ---------------------------------------------------------------------------

CLASS KnowledgeBase
   EXPORTED:
   METHOD lookup( cCategory )
ENDCLASS

METHOD KnowledgeBase:lookup( cCategory )
   UNUSED( cCategory )
RETURN ""

CLASS DemoKnowledgeBase FROM KnowledgeBase
   EXPORTED:
   METHOD lookup( cCategory )
ENDCLASS

METHOD DemoKnowledgeBase:lookup( cCategory )
   LOCAL cCat := Lower( If( cCategory == NIL, "", cCategory ) )

   DO CASE
   CASE cCat == "billing"
      RETURN "Refunds are processed within 5-7 business days. Double charges are " + ;
             "reversed once verified against the payment log."
   CASE cCat == "technical"
      RETURN "Ask for product version and OS. Known login issues are resolved by " + ;
             "clearing the session token and retrying."
   CASE cCat == "account"
      RETURN "Account changes require identity verification. Password resets are " + ;
             "self-service from the login screen."
   ENDCASE

RETURN "Be courteous, acknowledge the issue, and set a clear next step."


// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// XML config loading
//
// Inbound tickets are read from a simple XML file (support-triage-emails.config)
// with the Xbase++ XmlSimpleParser(). Document shape:
//
//   <emails>
//     <email><channel/><subject/><body/></email>
//     ...
//   </emails>
// ---------------------------------------------------------------------------

/// <summary>
/// Read the XML config and turn each email element into an InboundMessage.
/// </summary>
/// <remarks>
/// Returns an empty array (and prints why) when the file is missing/empty or the
/// XML is malformed - XmlSimpleParser() raises an "XML" subsystem error on bad
/// input, caught here so a typo in the config does not crash the whole run.
/// </remarks>
/// <param name="cConfigFile">path to the XML config file</param>
/// <returns>array of InboundMessage</returns>
///
FUNCTION LoadInboundMessages( cConfigFile )
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
      // Document root is <emails>; <email> children are read by name. A single
      // child parses to one node, several to an array - normalise to an array
      // so the caller can always iterate.
      oXml   := XmlSimpleParser( cXml )
      aNodes := oXml:emails:email

      IF ValType( aNodes ) == "O"
         aNodes := { aNodes }
      ENDIF

      FOR nI := 1 TO Len( aNodes )
         AAdd( aOut, NodeToMessage( aNodes[nI] ) )
      NEXT
   RECOVER USING oError
      ? "Failed to parse " + cConfigFile + ":", oError:description
      aOut := {}
   END SEQUENCE

RETURN aOut


/// <summary>
/// Build an InboundMessage from an XML email node.
/// </summary>
/// <remarks>
/// Leaf elements are read as members (XmlSimpleParser idiom) and AllTrim()-ed
/// to drop indentation whitespace. ANSI-to-UTF-8 conversion is handled by
/// the framework at the HTTP boundary.
/// </remarks>
/// <param name="oNode">parsed XML email node</param>
/// <returns>InboundMessage</returns>
///
FUNCTION NodeToMessage( oNode )
RETURN InboundMessage():New( AllTrim( oNode:subject ), ;
                             AllTrim( oNode:body ), ;
                             AllTrim( oNode:channel ) )


// ---------------------------------------------------------------------------
// Personas
//
// Each class method returns a ready-made PromptContributor describing the
// model's role for that step. Defined once here; used by name in the agent.
// ---------------------------------------------------------------------------

CLASS SupportPersonas

   EXPORTED:
   CLASS METHOD classifier()
   CLASS METHOD sentimentAnalyst()
   CLASS METHOD drafter()
   CLASS METHOD escalator()

ENDCLASS

/// <summary>
/// Persona for the ticket classification step.
/// </summary>
///
CLASS METHOD SupportPersonas:classifier()
RETURN RoleGoalBackstory():create( ;
   "Support ticket triage specialist",                                        ;
   "Classify inbound support tickets by type and urgency",                   ;
   "Experienced at spotting billing, technical, account, and general issues" )

/// <summary>
/// Persona for the sentiment assessment step.
/// </summary>
///
CLASS METHOD SupportPersonas:sentimentAnalyst()
RETURN RoleGoalBackstory():create( ;
   "Customer sentiment analyst",                                       ;
   "Assess the emotional tone of customer support messages",           ;
   "Expert in reading frustration, satisfaction, and urgency in text" )

/// <summary>
/// Persona for the draft reply step.
/// </summary>
///
CLASS METHOD SupportPersonas:drafter()
RETURN RoleGoalBackstory():create( ;
   "Customer support agent",                                                         ;
   "Draft concise, accurate first responses for a human colleague to review",        ;
   "Friendly writer who never overpromises and always replies in the customer's language" )

/// <summary>
/// Persona for the escalation summary step.
/// </summary>
///
CLASS METHOD SupportPersonas:escalator()
RETURN RoleGoalBackstory():create( ;
   "Support escalation specialist",                                   ;
   "Summarise high-risk tickets clearly for senior agent handover",   ;
   "Concise and factual; captures type, urgency, and sentiment precisely" )


// ---------------------------------------------------------------------------
// Custom prompt contributors
//
// These carry live, per-call context that cannot live in a static persona.
// ---------------------------------------------------------------------------

/// <summary>
/// KnowledgeBaseContributor - injects the ticket category and the relevant
/// knowledge base guidance into the system prompt for the draft reply step.
/// </summary>
///
CLASS KnowledgeBaseContributor FROM PromptContributor

   EXPORTED:
   VAR category
   VAR knowledgeBase

   METHOD init( cCategory, oKnowledgeBase )
   METHOD contribution()

ENDCLASS

METHOD KnowledgeBaseContributor:init( cCategory, oKnowledgeBase )
   ::PromptContributor:init()
   ::category      := cCategory
   ::knowledgeBase := oKnowledgeBase
RETURN Self

METHOD KnowledgeBaseContributor:contribution()
   LOCAL cCat := AllTrim( If( ::category == NIL, "general", ::category ) )
RETURN "Ticket category: " + cCat + CRLF + ;
       "Relevant knowledge base guidance:" + CRLF + ;
       ::knowledgeBase:lookup( ::category ) + CRLF + ;
       "Keep it under 120 words. Do not promise anything the guidance does not support."