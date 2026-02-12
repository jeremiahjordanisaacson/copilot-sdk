/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/
package com.github.copilot;

import java.util.Map;

/**
 * Options for creating a CopilotClient.
 */
public class CopilotClientOptions {
    private String cliPath;
    private String[] cliArgs;
    private String cwd;
    private int port;
    private Boolean useStdio;
    private String cliUrl;
    private String logLevel;
    private Boolean autoStart;
    private Boolean autoRestart;
    private Map<String, String> env;
    private String githubToken;
    private Boolean useLoggedInUser;

    public CopilotClientOptions() {}

    // Builder-style setters
    public CopilotClientOptions cliPath(String cliPath) { this.cliPath = cliPath; return this; }
    public CopilotClientOptions cliArgs(String[] args) { this.cliArgs = args; return this; }
    public CopilotClientOptions cwd(String cwd) { this.cwd = cwd; return this; }
    public CopilotClientOptions port(int port) { this.port = port; return this; }
    public CopilotClientOptions useStdio(boolean useStdio) { this.useStdio = useStdio; return this; }
    public CopilotClientOptions cliUrl(String cliUrl) { this.cliUrl = cliUrl; return this; }
    public CopilotClientOptions logLevel(String logLevel) { this.logLevel = logLevel; return this; }
    public CopilotClientOptions autoStart(boolean autoStart) { this.autoStart = autoStart; return this; }
    public CopilotClientOptions autoRestart(boolean autoRestart) { this.autoRestart = autoRestart; return this; }
    public CopilotClientOptions env(Map<String, String> env) { this.env = env; return this; }
    public CopilotClientOptions githubToken(String token) { this.githubToken = token; return this; }
    public CopilotClientOptions useLoggedInUser(boolean use) { this.useLoggedInUser = use; return this; }

    // Getters
    public String getCliPath() { return cliPath; }
    public String[] getCliArgs() { return cliArgs; }
    public String getCwd() { return cwd; }
    public int getPort() { return port; }
    public Boolean getUseStdio() { return useStdio; }
    public String getCliUrl() { return cliUrl; }
    public String getLogLevel() { return logLevel; }
    public Boolean getAutoStart() { return autoStart; }
    public Boolean getAutoRestart() { return autoRestart; }
    public Map<String, String> getEnv() { return env; }
    public String getGithubToken() { return githubToken; }
    public Boolean getUseLoggedInUser() { return useLoggedInUser; }
}
