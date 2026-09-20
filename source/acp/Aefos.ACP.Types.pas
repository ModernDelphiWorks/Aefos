unit Aefos.ACP.Types;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Aefos ACP (Agent Client Protocol) - Core Domain Types
  Standardized JSON-RPC 2.0 based protocol contracts for AI agents and executors.
  Aligned with official registry specification: https://github.com/agentclientprotocol/registry

  Pure abstraction layer: no Vcl.*, no ToolsAPI.
  Compatible with Delphi 12/13 and Lazarus/FPC.
}

interface

uses
  SysUtils,
  Classes;

type
  // Authentication mechanisms announced by an ACP agent
  TACPAuthKind = (
    akNone,          // No credentials required
    akOAuthBrowser,  // Browser login flow (e.g. Claude Subscription, Google OAuth)
    akApiKey,        // Raw token / API key
    akCustom         // Custom agent-defined auth
  );

  // Status of the agent connection
  TACPAgentStatus = (
    asDisconnected,
    asConnecting,
    asConnected,
    asAuthRequired,
    asError
  );

  // Description of an authentication method supported by the agent
  TACPAuthMethod = record
    Kind: TACPAuthKind;
    Name: string;         // 'Claude Subscription', 'Anthropic Console', etc.
    Description: string;
    AuthUrl: string;
    Authenticated: Boolean;
    AccountEmail: string;
  end;

  // Model announced dynamically by the ACP agent or managed by user
  TACPModelInfo = record
    Id: string;           // 'claude-3-7-sonnet-latest', 'gemini-2.5-pro'
    Name: string;
    Description: string;
    ContextLength: Integer;
    SupportsTools: Boolean;
    IsCustom: Boolean;    // True if manually added by user
  end;

  // Distribution descriptor from registry agent.json
  TACPDistribution = record
    PackageType: string;  // 'npx', 'binary', etc.
    PackageName: string;  // '@agentclientprotocol/claude-agent-acp@0.79.0'
  end;

  // Manifest entry for an ACP agent (Registry & Installed list)
  TACPAgentManifest = record
    Id: string;           // 'claude-acp', 'codex-acp', 'antigravity-acp'
    Name: string;         // Display name: 'Claude Agent'
    Version: string;      // '0.79.0'
    Authors: string;      // 'Anthropic, Zed Industries, JetBrains'
    Description: string;
    License: string;      // 'proprietary', 'Apache-2.0', 'MIT'
    RepositoryUrl: string;
    LicenseUrl: string;
    Distribution: TACPDistribution;
    ExecutablePath: string; // Absolute path or command to spawn
    Args: TArray<string>;   // Default spawn arguments
    Installed: Boolean;
    Active: Boolean;        // Currently active for AI Chat
    AuthMethods: TArray<TACPAuthMethod>;
    Models: TArray<TACPModelInfo>;
    SelectedModelId: string;
    SelectedAuthKind: TACPAuthKind;
    ApiKey: string;
    Status: TACPAgentStatus;
    StatusMessage: string;
  end;

  // JSON-RPC Request frame
  TACPJsonRpcRequest = record
    JsonRpc: string;     // '2.0'
    Id: Int64;
    Method: string;
    ParamsJson: string;
  end;

  // JSON-RPC Response frame
  TACPJsonRpcResponse = record
    JsonRpc: string;
    Id: Int64;
    ResultJson: string;
    ErrorCode: Integer;
    ErrorMessage: string;
    IsError: Boolean;
  end;

  // Callbacks for agent interaction
  {$IFDEF FPC}
  TACPPromptChunkProc = procedure(const AChunk: string) of object;
  TACPPromptDoneProc = procedure(const AFullText: string) of object;
  TACPErrorProc = procedure(const AErrorCode: Integer; const AMessage: string) of object;
  {$ELSE}
  TACPPromptChunkProc = reference to procedure(const AChunk: string);
  TACPPromptDoneProc = reference to procedure(const AFullText: string);
  TACPErrorProc = reference to procedure(const AErrorCode: Integer; const AMessage: string);
  {$ENDIF}

implementation

end.
