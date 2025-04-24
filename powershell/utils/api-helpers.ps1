# API Helper Functions for OpenRouter Chat Client
# These functions handle API communication and response processing with OpenRouter

function Get-Configuration {
    <#
    .SYNOPSIS
        Loads the configuration from config.json
    .DESCRIPTION
        Reads and parses the configuration file, which contains API settings and chat defaults
    .EXAMPLE
        $config = Get-Configuration
    #>
    
    $scriptPath = Split-Path -Parent $PSScriptRoot
    $configPath = Join-Path -Path $scriptPath -ChildPath "config.json"
    
    if (-not (Test-Path $configPath)) {
        Write-Error "Configuration file not found at: $configPath"
        exit 1
    }
    
    try {
        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
        return $config
    }
    catch {
        Write-Error "Failed to parse configuration file: $_"
        exit 1
    }
}

function Test-ApiKey {
    <#
    .SYNOPSIS
        Tests if the API key is valid and configured
    .DESCRIPTION
        Checks if the API key is present in the configuration and validates it with a simple API call
    .PARAMETER Config
        The configuration object containing the API settings
    .EXAMPLE
        Test-ApiKey -Config $config
    #>
    
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )
    
    if ([string]::IsNullOrWhiteSpace($Config.api.apiKey)) {
        Write-Host "API key is not configured in config.json" -ForegroundColor Yellow
        $apiKey = Read-Host -Prompt "Please enter your OpenRouter API key" -AsSecureString
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($apiKey)
        $Config.api.apiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        
        # Save the API key to config.json
        $scriptPath = Split-Path -Parent $PSScriptRoot
        $configPath = Join-Path -Path $scriptPath -ChildPath "config.json"
        $Config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath
        
        Write-Host "API key saved to config.json" -ForegroundColor Green
    }
    
    # Test the API key with a simple request
    try {
        $headers = @{
            "Authorization" = "Bearer $($Config.api.apiKey)"
            "Content-Type"  = "application/json"
            "HTTP-Referer"  = "https://ai101.example.com"  # Optional: helps OpenRouter track API usage
            "X-Title"       = "AI101 Chat Client"          # Optional: helps OpenRouter track API usage
        }
        
        $body = @{
            "model"      = $Config.api.model
            "messages"   = @(
                @{
                    "role"    = "user"
                    "content" = "Hello"
                }
            )
            "max_tokens" = 5
        } | ConvertTo-Json
        
        # Store the response and use it to validate
        $apiResponse = Invoke-RestMethod -Uri $Config.api.endpoint -Method Post -Headers $headers -Body $body
        Write-Host "API key is valid" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "API key validation failed: $_" -ForegroundColor Red
        return $false
    }
}

function Invoke-ChatCompletion {
    <#
    .SYNOPSIS
        Sends a chat completion request to the OpenRouter API
    .DESCRIPTION
        Formats the conversation history and sends it to the OpenRouter API for completion
    .PARAMETER Config
        The configuration object containing API settings
    .PARAMETER Messages
        An array of message objects representing the conversation history
    .PARAMETER ImageUrl
        Optional URL to an image for multimodal requests
    .EXAMPLE
        $response = Invoke-ChatCompletion -Config $config -Messages $messages
    .EXAMPLE
        $response = Invoke-ChatCompletion -Config $config -Messages $messages -ImageUrl "https://example.com/image.jpg"
    #>
    
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,
        
        [Parameter(Mandatory = $true)]
        [Array]$Messages,
        
        [Parameter(Mandatory = $false)]
        [string]$ImageUrl
    )
    
    $headers = @{
        "Authorization" = "Bearer $($Config.api.apiKey)"
        "Content-Type"  = "application/json"
        "HTTP-Referer"  = "https://ai101.example.com"  # Optional: helps OpenRouter track API usage
        "X-Title"       = "AI101 Chat Client"          # Optional: helps OpenRouter track API usage
    }
    
    # Process the last user message to check if we need to add an image
    if (-not [string]::IsNullOrWhiteSpace($ImageUrl) -and $Messages.Count -gt 0) {
        $lastMessageIndex = $Messages.Count - 1
        
        # Find the last user message
        for ($i = $lastMessageIndex; $i -ge 0; $i--) {
            if ($Messages[$i].role -eq "user") {
                # Convert the simple text content to a structured content array with text and image
                $originalContent = $Messages[$i].content
                $Messages[$i].content = @(
                    @{
                        "type" = "text"
                        "text" = $originalContent
                    },
                    @{
                        "type" = "image_url"
                        "image_url" = @{
                            "url" = $ImageUrl
                        }
                    }
                )
                break
            }
        }
    }
    
    $body = @{
        "model"       = $Config.api.model
        "messages"    = $Messages
        "temperature" = $Config.api.temperature
        "max_tokens"  = $Config.api.max_tokens
    } | ConvertTo-Json -Depth 10
    
    try {
        Write-Host "Sending request to OpenRouter API..." -ForegroundColor Cyan
        $response = Invoke-RestMethod -Uri $Config.api.endpoint -Method Post -Headers $headers -Body $body
        return $response.choices[0].message
    }
    catch {
        Write-Host "API request failed: $_" -ForegroundColor Red
        return $null
    }
}

function Save-Conversation {
    <#
    .SYNOPSIS
        Saves the conversation history to a JSON file
    .DESCRIPTION
        Serializes the conversation history and saves it to the specified file
    .PARAMETER Config
        The configuration object containing save settings
    .PARAMETER Messages
        An array of message objects representing the conversation history
    .PARAMETER FilePath
        Optional path to save the conversation. If not provided, uses the default from config
    .EXAMPLE
        Save-Conversation -Config $config -Messages $messages
    .EXAMPLE
        Save-Conversation -Config $config -Messages $messages -FilePath "C:\path\to\save.json"
    #>
    
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,
        
        [Parameter(Mandatory = $true)]
        [Array]$Messages,
        
        [Parameter(Mandatory = $false)]
        [string]$FilePath
    )
    
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        $saveDir = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath $Config.chat.save_directory
        
        if (-not (Test-Path $saveDir)) {
            New-Item -ItemType Directory -Path $saveDir -Force | Out-Null
        }
        
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $FilePath = Join-Path -Path $saveDir -ChildPath "$timestamp`_$($Config.chat.default_filename)"
    }
    
    try {
        $conversationData = @{
            "timestamp" = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            "model"     = $Config.api.model
            "messages"  = $Messages
        }
        
        $conversationData | ConvertTo-Json -Depth 10 | Set-Content -Path $FilePath
        Write-Host "Conversation saved to: $FilePath" -ForegroundColor Green
        return $FilePath
    }
    catch {
        Write-Host "Failed to save conversation: $_" -ForegroundColor Red
        return $null
    }
}

function Import-Conversation {
    <#
    .SYNOPSIS
        Imports a conversation history from a JSON file
    .DESCRIPTION
        Deserializes a conversation history from the specified file
    .PARAMETER FilePath
        Path to the conversation JSON file
    .EXAMPLE
        $messages = Import-Conversation -FilePath "C:\path\to\conversation.json"
    #>
    
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )
    
    if (-not (Test-Path $FilePath)) {
        Write-Host "Conversation file not found: $FilePath" -ForegroundColor Red
        return $null
    }
    
    try {
        $conversationData = Get-Content -Path $FilePath -Raw | ConvertFrom-Json
        Write-Host "Loaded conversation from: $FilePath" -ForegroundColor Green
        Write-Host "Conversation timestamp: $($conversationData.timestamp)" -ForegroundColor Cyan
        Write-Host "Model used: $($conversationData.model)" -ForegroundColor Cyan
        
        return $conversationData.messages
    }
    catch {
        Write-Host "Failed to load conversation: $_" -ForegroundColor Red
        return $null
    }
}

# Export functions
Export-ModuleMember -Function Get-Configuration, Test-ApiKey, Invoke-ChatCompletion, Save-Conversation, Import-Conversation
