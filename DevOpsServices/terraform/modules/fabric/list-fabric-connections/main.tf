terraform {
  required_providers {
    fabric = {
      source  = "microsoft/fabric"
      version = "1.1.0"
    }
  }
}

resource "null_resource" "get_fabric_connections" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOT
      $TenantId = $env:ARM_TENANT_ID
      $ClientId = $env:ARM_CLIENT_ID
      $ClientSecret = $env:ARM_CLIENT_SECRET
     
      Write-Host "Getting Fabric connections... TenantId: $TenantId, ClientId: $ClientId"
      try {
        # Get token
        $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        $body = @{
          grant_type    = "client_credentials"
          client_id     = $ClientId
          client_secret = $ClientSecret
          scope         = "https://api.fabric.microsoft.com/.default"
        }
       
        $response = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Body $body
        $accessToken = $response.access_token
       
        Write-Host "Token obtained successfully"
       
        # Get connections
        $headers = @{
          'Authorization' = "Bearer $accessToken"
          'Content-Type'  = 'application/json'
        }
       
        $connectionsUrl = "https://api.fabric.microsoft.com/v1/connections"
        $response = Invoke-RestMethod -Method Get -Uri $connectionsUrl -Headers $headers
       
        # Ensure we have valid data before writing
        if ($response.value) {
          # Force array with @() and ensure proper object structure
          $connections = @($response.value | Select-Object displayName, id, connectivityType, connectionDetails)
         
          # Write to a temporary file first
          $tempFile = "${path.module}/connections.json.tmp"
         
          # Ensure it's written as an array
          @($connections) | ConvertTo-Json -Depth 10 | Out-File -FilePath $tempFile -Encoding UTF8
         
          Write-Host "Found $($connections.Count) connections"
         
          # Move to final location only if successful
          Move-Item -Path $tempFile -Destination "${path.module}/connections.json" -Force
          Write-Host "Successfully wrote connections to file"
        } else {
          Write-Host "No connections found"
          # Write empty array if no connections found
          '[]' | Out-File -FilePath "${path.module}/connections.json" -Encoding UTF8
        }
      }
      catch {
        Write-Error "Failed to get connections: $_"
        if ($_.ErrorDetails) {
          Write-Error "Error details: $($_.ErrorDetails)"
        }
        # Ensure we have a valid JSON array even on error
        '[]' | Out-File -FilePath "${path.module}/connections.json" -Encoding UTF8
        throw
      }
    EOT

    interpreter = ["powershell", "-Command"]

    environment = {
      ARM_CLIENT_ID     = null
      ARM_CLIENT_SECRET = null
      ARM_TENANT_ID     = null
    }
  }
}

# Read the JSON file
data "local_file" "connections_json" {
  depends_on = [null_resource.get_fabric_connections]
  filename   = "${path.module}/connections.json"
}

locals {
  connections_raw = data.local_file.connections_json.content
  # Debug output
  raw_content = local.connections_raw
}

