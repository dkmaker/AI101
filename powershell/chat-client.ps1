# OpenRouter Chat Client for PowerShell
# This script provides a command-line interface for interacting with OpenRouter's LLM API
# It maintains conversation history and can save/load conversations as JSON files

param (
    [string]$ConversationPath,
    [string]$SystemPrompt,
    [switch]$SaveOnExit
)

# Import utility functions
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$utilsPath = Join-Path -Path $scriptPath -ChildPath "utils\api-helpers.ps1"

if (-not (Test-Path $utilsPath)) {
    Write-Error "Utility functions not found at: $utilsPath"
    exit 1
}

. $utilsPath

# Function to save current state to examples/current.json
function Save-CurrentState {
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,
        
        [Parameter(Mandatory = $true)]
        [Array]$Messages
    )
    
    $saveDir = Join-Path -Path $scriptPath -ChildPath $Config.chat.save_directory
    
    if (-not (Test-Path $saveDir)) {
        New-Item -ItemType Directory -Path $saveDir -Force | Out-Null
    }
    
    $currentPath = Join-Path -Path $saveDir -ChildPath "current.json"
    
    try {
        $currentData = @{
            "timestamp" = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            "model"     = $Config.api.model
            "messages"  = $Messages
        }
        
        $currentData | ConvertTo-Json -Depth 10 | Set-Content -Path $currentPath
        return $true
    }
    catch {
        Write-Host "Failed to save current state: $_" -ForegroundColor Red
        return $false
    }
}

# Load configuration
$config = Get-Configuration

# Validate API key
if (-not (Test-ApiKey -Config $config)) {
    Write-Host "Please check your API key and try again." -ForegroundColor Red
    exit 1
}

# Delete current.json if it exists to start fresh
$saveDir = Join-Path -Path $scriptPath -ChildPath $config.chat.save_directory
$currentPath = Join-Path -Path $saveDir -ChildPath "current.json"
if (Test-Path $currentPath) {
    Remove-Item -Path $currentPath -Force
    Write-Host "Removed previous session state." -ForegroundColor Gray
}

# Ensure the examples directory exists
if (-not (Test-Path $saveDir)) {
    New-Item -ItemType Directory -Path $saveDir -Force | Out-Null
    Write-Host "Created save directory: $saveDir" -ForegroundColor Gray
}

# Initialize conversation history
$messages = @()

# Load existing conversation if specified
if ($ConversationPath) {
    $loadedMessages = Import-Conversation -FilePath $ConversationPath
    if ($loadedMessages) {
        $messages = $loadedMessages
        
        # Display conversation summary
        Write-Host "Loaded conversation with $($messages.Count) messages" -ForegroundColor Cyan
        
        # Show the last few messages for context
        $lastMessages = $messages | Select-Object -Last 3
        Write-Host "Last few messages:" -ForegroundColor Cyan
        foreach ($msg in $lastMessages) {
            $roleColor = switch ($msg.role) {
                "system" { "Magenta" }
                "user" { "Green" }
                "assistant" { "Blue" }
                default { "White" }
            }
            
            Write-Host "[$($msg.role)]" -ForegroundColor $roleColor -NoNewline
            Write-Host " $($msg.content.Substring(0, [Math]::Min(50, $msg.content.Length)))..." -ForegroundColor Gray
        }
        
        # Save current state after loading a conversation
        Save-CurrentState -Config $config -Messages $messages | Out-Null
    }
}

# Add system prompt if specified or use default
if ($messages.Count -eq 0 -or $messages[0].role -ne "system") {
    $systemPromptContent = if ($SystemPrompt) { $SystemPrompt } else { $config.chat.default_system_prompt }
    $systemMessage = @{
        "role"    = "system"
        "content" = $systemPromptContent
    }
    
    if ($messages.Count -eq 0) {
        $messages = @($systemMessage)
    }
    else {
        $messages = @($systemMessage) + $messages
    }
    
    Write-Host "Using system prompt: $systemPromptContent" -ForegroundColor Magenta
    
    # Save current state after initializing system prompt
    Save-CurrentState -Config $config -Messages $messages | Out-Null
}

# Variable to store image URL for multimodal messages
$imageUrl = $null

# Display welcome message
Write-Host "`n===== OpenRouter Chat Client =====`n" -ForegroundColor Cyan
Write-Host "Type your messages and press Enter to send." -ForegroundColor Cyan
Write-Host "Special commands:" -ForegroundColor Yellow
Write-Host "  /exit         - Exit the chat" -ForegroundColor Yellow
Write-Host "  /save [path]  - Save the conversation" -ForegroundColor Yellow
Write-Host "  /system [text] - Change the system prompt" -ForegroundColor Yellow
Write-Host "  /model [name] - Change the model" -ForegroundColor Yellow
Write-Host "  /image [url]  - Include an image with your next message" -ForegroundColor Yellow
Write-Host "  /clear        - Clear the conversation history" -ForegroundColor Yellow
Write-Host "  /help         - Show this help message" -ForegroundColor Yellow
Write-Host "`nCurrent model: $($config.api.model)" -ForegroundColor Cyan
Write-Host "Max tokens: $($config.api.max_tokens)" -ForegroundColor Cyan
Write-Host "Temperature: $($config.api.temperature)" -ForegroundColor Cyan
Write-Host "`n" -ForegroundColor Cyan

# Function to display assistant response
function Show-AssistantResponse {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ResponseText
    )
    
    # Define code block delimiter (triple backticks) as a variable to avoid escaping issues
    $codeBlockDelimiter = [char]96 + [char]96 + [char]96  # ASCII code for backtick
    
    # Simple markdown processing for code blocks
    $inCodeBlock = $false
    $codeLanguage = ""
    
    foreach ($line in ($ResponseText -split "`n")) {
        if ($line -match "^$codeBlockDelimiter(.*)$") {
            $inCodeBlock = -not $inCodeBlock
            $codeLanguage = $matches[1]
            
            if ($inCodeBlock) {
                Write-Host "$codeBlockDelimiter$codeLanguage" -ForegroundColor DarkGray
            }
            else {
                Write-Host $codeBlockDelimiter -ForegroundColor DarkGray
            }
        }
        elseif ($inCodeBlock) {
            Write-Host $line -ForegroundColor Yellow
        }
        else {
            # Simple output for regular text
            Write-Host $line
        }
    }
    
    Write-Host ""
}

# Main chat loop
try {
    while ($true) {
        # Get user input
        Write-Host "You: " -ForegroundColor Green -NoNewline
        $userInput = Read-Host
        
        # Process special commands
        if ($userInput.StartsWith("/")) {
            $commandParts = $userInput.Split(" ", 2)
            $command = $commandParts[0].ToLower()
            $commandArgs = if ($commandParts.Length -gt 1) { $commandParts[1] } else { "" }
            
            if ($command -eq "/exit") {
                if ($SaveOnExit) {
                    $savePath = Save-Conversation -Config $config -Messages $messages
                    Write-Host "Conversation saved to: $savePath" -ForegroundColor Green
                }
                Write-Host "Exiting chat. Goodbye!" -ForegroundColor Cyan
                exit 0
            }
            elseif ($command -eq "/save") {
                $savePath = if ($commandArgs) { $commandArgs } else { $null }
                $savedPath = Save-Conversation -Config $config -Messages $messages -FilePath $savePath
                if ($savedPath) {
                    Write-Host "Conversation saved to: $savedPath" -ForegroundColor Green
                }
                continue
            }
            elseif ($command -eq "/system") {
                if ([string]::IsNullOrWhiteSpace($commandArgs)) {
                    Write-Host "Current system prompt: $($messages[0].content)" -ForegroundColor Magenta
                }
                else {
                    $messages[0].content = $commandArgs
                    Write-Host "System prompt updated to: $commandArgs" -ForegroundColor Magenta
                    
                    # Save current state
                    Save-CurrentState -Config $config -Messages $messages | Out-Null
                }
                continue
            }
            elseif ($command -eq "/model") {
                if ([string]::IsNullOrWhiteSpace($commandArgs)) {
                    Write-Host "Current model: $($config.api.model)" -ForegroundColor Cyan
                }
                else {
                    $config.api.model = $commandArgs
                    Write-Host "Model updated to: $commandArgs" -ForegroundColor Cyan
                    
                    # Save the updated model to config.json
                    $configPath = Join-Path -Path $scriptPath -ChildPath "config.json"
                    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath
                    
                    # Save current state
                    Save-CurrentState -Config $config -Messages $messages | Out-Null
                }
                continue
            }
            elseif ($command -eq "/image") {
                if ([string]::IsNullOrWhiteSpace($commandArgs)) {
                    Write-Host "Please provide an image URL. Usage: /image [url]" -ForegroundColor Yellow
                }
                else {
                    $imageUrl = $commandArgs
                    Write-Host "Image URL set: $imageUrl" -ForegroundColor Green
                    Write-Host "Type your message to send along with this image..." -ForegroundColor Cyan
                }
                continue
            }
            elseif ($command -eq "/clear") {
                $systemPrompt = $messages[0].content
                $messages = @(
                    @{
                        "role" = "system"
                        "content" = $systemPrompt
                    }
                )
                Write-Host "Conversation history cleared." -ForegroundColor Yellow
                
                # Save current state
                Save-CurrentState -Config $config -Messages $messages | Out-Null
                continue
            }
            elseif ($command -eq "/help") {
                Write-Host "`nSpecial commands:" -ForegroundColor Yellow
                Write-Host "  /exit         - Exit the chat" -ForegroundColor Yellow
                Write-Host "  /save [path]  - Save the conversation" -ForegroundColor Yellow
                Write-Host "  /system [text] - Change the system prompt" -ForegroundColor Yellow
                Write-Host "  /model [name] - Change the model" -ForegroundColor Yellow
                Write-Host "  /image [url]  - Include an image with your next message" -ForegroundColor Yellow
                Write-Host "  /clear        - Clear the conversation history" -ForegroundColor Yellow
                Write-Host "  /help         - Show this help message" -ForegroundColor Yellow
                Write-Host "`nCurrent model: $($config.api.model)" -ForegroundColor Cyan
                Write-Host "Max tokens: $($config.api.max_tokens)" -ForegroundColor Cyan
                Write-Host "Temperature: $($config.api.temperature)" -ForegroundColor Cyan
                Write-Host "`n" -ForegroundColor Cyan
                continue
            }
            else {
                Write-Host "Unknown command: $command" -ForegroundColor Red
                continue
            }
        }
        
        # Add user message to history
        $messages += @{
            "role" = "user"
            "content" = $userInput
        }
        
        # Get response from API, with image if specified
        $response = if ($imageUrl) {
            $result = Invoke-ChatCompletion -Config $config -Messages $messages -ImageUrl $imageUrl
            # Clear the image URL after use
            $imageUrl = $null
            $result
        } else {
            Invoke-ChatCompletion -Config $config -Messages $messages
        }
        
        if ($response) {
            # Add assistant response to history
            $messages += $response
            
            # Display assistant response
            Write-Host "Assistant: " -ForegroundColor Blue
            Show-AssistantResponse -ResponseText $response.content
            
            # Save current state after each response
            Save-CurrentState -Config $config -Messages $messages | Out-Null
        }
        else {
            Write-Host "Failed to get a response from the API." -ForegroundColor Red
            # Remove the last user message since we didn't get a response
            $messages = $messages[0..($messages.Count - 2)]
        }
    }
}
catch {
    Write-Host "An error occurred: $_" -ForegroundColor Red
}
finally {
    # Save conversation on exit if requested
    if ($SaveOnExit -and $messages.Count -gt 1) {
        $savePath = Save-Conversation -Config $config -Messages $messages
        Write-Host "Conversation saved to: $savePath" -ForegroundColor Green
    }
}
