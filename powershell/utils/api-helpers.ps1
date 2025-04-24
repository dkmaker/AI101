# API Helper Functions for OpenRouter Chat Client
# These functions handle API communication and response processing with OpenRouter

function Get-EnvVariables {
    <#
    .SYNOPSIS
        Loads environment variables from a .env file
    .DESCRIPTION
        Parses a .env file and returns a hashtable of key-value pairs
    .PARAMETER EnvPath
        Path to the .env file
    .EXAMPLE
        $envVars = Get-EnvVariables -EnvPath ".env"
    #>
    
    param (
        [Parameter(Mandatory = $true)]
        [string]$EnvPath
    )
    
    $envVars = @{}
    
    if (Test-Path $EnvPath) {
        Get-Content $EnvPath | ForEach-Object {
            $line = $_.Trim()
            
            # Skip comments and empty lines
            if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.StartsWith('#')) {
                $keyValue = $line -split '=', 2
                if ($keyValue.Length -eq 2) {
                    $key = $keyValue[0].Trim()
                    $value = $keyValue[1].Trim()
                    
                    # Remove quotes if present
                    if ($value.StartsWith('"') -and $value.EndsWith('"')) {
                        $value = $value.Substring(1, $value.Length - 2)
                    }
                    elseif ($value.StartsWith("'") -and $value.EndsWith("'")) {
                        $value = $value.Substring(1, $value.Length - 2)
                    }
                    
                    $envVars[$key] = $value
                }
            }
        }
    }
    
    return $envVars
}

function Get-Configuration {
    <#
    .SYNOPSIS
        Loads the configuration from config.json and .env file if present
    .DESCRIPTION
        Reads and parses the configuration file and environment variables,
        with .env values taking precedence over config.json values
    .EXAMPLE
        $config = Get-Configuration
    #>
    
    $scriptPath = Split-Path -Parent $PSScriptRoot
    $configPath = Join-Path -Path $scriptPath -ChildPath "config.json"
    $envPath = Join-Path -Path $scriptPath -ChildPath ".env"
    $exampleConfigPath = Join-Path -Path $scriptPath -ChildPath "config.example.json"
    
    # Check if config.json exists, if not suggest copying from example
    if (-not (Test-Path $configPath)) {
        if (Test-Path $exampleConfigPath) {
            Write-Host "Configuration file not found at: $configPath" -ForegroundColor Yellow
            Write-Host "You can create one by copying from config.example.json:" -ForegroundColor Yellow
            Write-Host "Copy-Item -Path '$exampleConfigPath' -Destination '$configPath'" -ForegroundColor Cyan
        } else {
            Write-Error "Configuration file not found at: $configPath and no example config found"
        }
        exit 1
    }
    
    try {
        # Load base configuration from config.json
        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
        
        # Load environment variables from .env file if it exists
        if (Test-Path $envPath) {
            $envVars = Get-EnvVariables -EnvPath $envPath
            
            # Override config values with environment variables
            if ($envVars.ContainsKey("OPENROUTER_API_KEY")) {
                $config.api.apiKey = $envVars["OPENROUTER_API_KEY"]
            }
            
            if ($envVars.ContainsKey("OPENROUTER_MODEL")) {
                $config.api.model = $envVars["OPENROUTER_MODEL"]
            }
            
            if ($envVars.ContainsKey("OPENROUTER_TEMPERATURE")) {
                $config.api.temperature = [double]$envVars["OPENROUTER_TEMPERATURE"]
            }
            
            if ($envVars.ContainsKey("OPENROUTER_MAX_TOKENS")) {
                $config.api.max_tokens = [int]$envVars["OPENROUTER_MAX_TOKENS"]
            }
        }
        
        return $config
    }
    catch {
        Write-Error "Failed to parse configuration: $_"
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
        $scriptPath = Split-Path -Parent $PSScriptRoot
        $envPath = Join-Path -Path $scriptPath -ChildPath ".env"
        
        Write-Host "API key is not configured" -ForegroundColor Yellow
        Write-Host "You can set it in one of two ways:" -ForegroundColor Yellow
        Write-Host "1. Create a .env file at $envPath with OPENROUTER_API_KEY=your_key_here" -ForegroundColor Yellow
        Write-Host "2. Enter it now (it will be stored in memory only for this session)" -ForegroundColor Yellow
        
        $apiKey = Read-Host -Prompt "Please enter your OpenRouter API key" -AsSecureString
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($apiKey)
        $Config.api.apiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        
        # Ask if user wants to save to .env file
        $saveToEnv = Read-Host -Prompt "Do you want to save this API key to a .env file? (y/n)"
        if ($saveToEnv.ToLower() -eq 'y') {
            if (Test-Path $envPath) {
                # Update existing .env file
                $envContent = Get-Content -Path $envPath
                $keyExists = $false
                
                for ($i = 0; $i -lt $envContent.Count; $i++) {
                    if ($envContent[$i] -match '^OPENROUTER_API_KEY=') {
                        $envContent[$i] = "OPENROUTER_API_KEY=$($Config.api.apiKey)"
                        $keyExists = $true
                        break
                    }
                }
                
                if (-not $keyExists) {
                    $envContent += "OPENROUTER_API_KEY=$($Config.api.apiKey)"
                }
                
                $envContent | Set-Content -Path $envPath
            } else {
                # Create new .env file
                "# OpenRouter API Configuration" | Set-Content -Path $envPath
                "OPENROUTER_API_KEY=$($Config.api.apiKey)" | Add-Content -Path $envPath
            }
            
            Write-Host "API key saved to .env file" -ForegroundColor Green
        } else {
            Write-Host "API key will be used for this session only" -ForegroundColor Yellow
        }
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
        Invoke-RestMethod -Uri $Config.api.endpoint -Method Post -Headers $headers -Body $body | Out-Null
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
                        "type"      = "image_url"
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

# Functions are automatically available when dot-sourced
# No need to export them explicitly
