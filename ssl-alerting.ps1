# Requires Az.Accounts, Az.Resources, Az.KeyVault
# Install-Module Az -Scope CurrentUser.

# =========================
# 1) Variables
# =========================

$subscriptionId          = "98d6ac31-3d59-42ab-99cd-f4dd44e9ba4c"
$resourceGroupName       = "sandbox-1"
$location                = "UK South"     
$logicAppName            = "sandbox-logicapp-1"
$office365ConnectionName = "office365"        # connection resource name
$keyVaultConnectionName  = "keyvault-1"       # connection resource name
$kvName                  = "sandbox-1-keyvault"     # e.g., kv-prod-01

# Save ARM next to this script
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$templatePath = Join-Path $PSScriptRoot 'logicapp-ssl-expiry-template.json'

# =========================
# 2) Login & context
# =========================
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop
Import-Module Az.KeyVault -ErrorAction Stop

if (-not (Get-AzContext)) {
    Connect-AzAccount -ErrorAction Stop | Out-Null
}
Set-AzContext -Subscription $subscriptionId -ErrorAction Stop | Out-Null

# =========================
# 3) Resource group
# =========================
$rg = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Host "Creating resource group '$resourceGroupName' in $location ..."
    New-AzResourceGroup -Name $resourceGroupName -Location $location -ErrorAction Stop | Out-Null
} else {
    Write-Host "Using existing resource group '$resourceGroupName'."
}


# =========================
# 4) ARM template
#    - Adds $connections declaration
#    - Uses host.connection.name = @parameters('$connections')[...]['connectionId']
#    - Configures Key Vault API connection with parameterValueSet 'oauthMI' and vaultName
#    - Enables SystemAssigned Managed Identity on the workflow.
# =========================
$template = @'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "logicAppName": { "type": "string" },
    "location": { "type": "string" },
    "office365ConnectionName": { "type": "string", "defaultValue": "office365" },
    "keyVaultConnectionName": { "type": "string", "defaultValue": "keyvault-1" },
    "kvName": { "type": "string" }
  },
  "resources": [
    {
      "type": "Microsoft.Web/connections",
      "apiVersion": "2016-06-01",
      "name": "[parameters('office365ConnectionName')]",
      "location": "[parameters('location')]",
      "properties": {
        "displayName": "[parameters('office365ConnectionName')]",
        "api": {
          "id": "[concat('/subscriptions/', subscription().subscriptionId, '/providers/Microsoft.Web/locations/', parameters('location'), '/managedApis/office365')]"
        }
      }
    },
    {
      "type": "Microsoft.Web/connections",
      "apiVersion": "2016-06-01",
      "name": "[parameters('keyVaultConnectionName')]",
      "location": "[parameters('location')]",
      "properties": {
        "displayName": "[parameters('keyVaultConnectionName')]",
        "parameterValueSet": {
          "name": "oauthMI",
          "values": {
            "vaultName": { "value": "[parameters('kvName')]" }
          }
        },
        "api": {
          "id": "[concat('/subscriptions/', subscription().subscriptionId, '/providers/Microsoft.Web/locations/', parameters('location'), '/managedApis/keyvault')]"
        }
      }
    },
    {
      "type": "Microsoft.Logic/workflows",
      "apiVersion": "2019-05-01",
      "name": "[parameters('logicAppName')]",
      "location": "[parameters('location')]",
      "identity": {
        "type": "SystemAssigned"
      },
      "properties": {
        "state": "Enabled",
        "definition": {
          "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
          "contentVersion": "1.0.0.0",
          "parameters": {
            "$connections": {
              "type": "Object",
              "defaultValue": {}
            }
          },
          "triggers": {
            "Recurrence": {
              "type": "Recurrence",
              "recurrence": {
                "frequency": "Day",
                "interval": 1,
                "timeZone": "India Standard Time"
              }
            }
          },
          "actions": {
            "Initialize_table_rows": {
              "type": "InitializeVariable",
              "inputs": {
                "variables": [
                  {
                    "name": "TableRows",
                    "type": "String",
                    "value": ""
                  }
                ]
              },
              "runAfter": {}
            },
            "List_secrets": {
              "type": "ApiConnection",
              "inputs": {
                "host": {
                  "connection": {
                    "name": "@parameters('$connections')['keyvault-1']['connectionId']"
                  }
                },
                "method": "get",
                "path": "/secrets"
              },
              "runAfter": {
                "Initialize_table_rows": [
                  "Succeeded"
                ]
              }
            },
            "For_each": {
              "type": "Foreach",
              "foreach": "@body('List_secrets')?['value']",
              "actions": {
                "Check_if_expiring_soon": {
                  "type": "If",
                  "expression": "@and(not(empty(items('For_each')?['validityEndTime'])), lessOrEquals(items('For_each')?['validityEndTime'], addDays(utcNow(), 30)))",
                  "actions": {
                    "Append_to_table_rows": {
                      "type": "AppendToStringVariable",
                      "inputs": {
                        "name": "TableRows",
                        "value": "@concat('<tr><td>', items('For_each')?['name'], '</td><td>', formatDateTime(items('For_each')?['validityEndTime'], 'dd-MMM-yyyy'), '</td></tr>')"
                      },
                      "runAfter": {}
                    }
                  },
                  "else": { "actions": {} }
                }
              },
              "runAfter": {
                "List_secrets": [ "Succeeded" ]
              }
            },
            "Check_if_any_rows": {
              "type": "If",
              "expression": "@greater(length(variables('TableRows')), 0)",
              "actions": {
                "Send_email_with_table": {
                  "type": "ApiConnection",
                  "inputs": {
                    "host": {
                      "connection": {
                        "name": "@parameters('$connections')['office365']['connectionId']"
                      }
                    },
                    "method": "post",
                    "path": "/v2/Mail",
                    "body": {
                      "To": "tejas.s@aspentech.com",
                      "Subject": "SSL Certification Expiration Summary",
                      "Body": "@{concat('<html><body><p>Hi Team,</p><p>Here is the summary of SSL Certificates that are expiring soon:</p><table border=\"1\" cellpadding=\"6\" cellspacing=\"0\" style=\"border-collapse: collapse; font-family: Arial, sans-serif;\"><thead style=\"background-color: #f2f2f2;\"><tr><th>SSL Certificate Name</th><th>Expiration Date</th></tr></thead><tbody>', variables('TableRows'), '</tbody></table><p>Please take necessary action to renew or rotate these secrets before they expire. Thank you!</p><p>Best regards,<br/>Azure Automation</p></body></html>')}",
                      "Importance": "Normal"
                    }
                  },
                  "runAfter": {}
                }
              },
              "else": {
                "actions": {
                  "Send_email_no_expiring_secrets": {
                    "type": "ApiConnection",
                    "inputs": {
                      "host": {
                        "connection": {
                          "name": "@parameters('$connections')['office365']['connectionId']"
                        }
                      },
                      "method": "post",
                      "path": "/v2/Mail",
                      "body": {
                        "To": "tejas.s@aspentech.com",
                        "Subject": "SSL Certification Expiration Summary",
                        "Body": "<html><body><p>Hi Team,</p><p>No SSL certificates are expiring in the next 30 days.</p><p>Thank you,<br>Azure Automation</p></body></html>",
                        "Importance": "Normal"
                      }
                    },
                    "runAfter": {}
                  }
                }
              },
              "runAfter": {
                "For_each": [ "Succeeded" ]
              }
            }
          },
          "outputs": {}
        },
        "parameters": {
          "$connections": {
            "value": {
              "office365": {
                "connectionId": "[resourceId('Microsoft.Web/connections', parameters('office365ConnectionName'))]",
                "connectionName": "[parameters('office365ConnectionName')]",
                "id": "[concat('/subscriptions/', subscription().subscriptionId, '/providers/Microsoft.Web/locations/', parameters('location'), '/managedApis/office365')]"
              },
              "keyvault-1": {
                "connectionId": "[resourceId('Microsoft.Web/connections', parameters('keyVaultConnectionName'))]",
                "connectionName": "[parameters('keyVaultConnectionName')]",
                "id": "[concat('/subscriptions/', subscription().subscriptionId, '/providers/Microsoft.Web/locations/', parameters('location'), '/managedApis/keyvault')]",
                "connectionProperties": {
                  "authentication": { "type": "ManagedServiceIdentity" }
                }
              }
            }
          }
        }
      },
      "dependsOn": [
        "[resourceId('Microsoft.Web/connections', parameters('office365ConnectionName'))]",
        "[resourceId('Microsoft.Web/connections', parameters('keyVaultConnectionName'))]"
      ]
    }
  ]
}
'@

# =========================
# 5) Save template to file
# =========================
Set-Content -Path $templatePath -Value $template -Encoding UTF8
Write-Host "Template written to: $templatePath"

# =========================
# 6) Parameters & validation
# =========================
$parameters = @{
  logicAppName            = $logicAppName
  location                = $location
  office365ConnectionName = $office365ConnectionName
  keyVaultConnectionName  = $keyVaultConnectionName
  kvName                  = $kvName
}

# Optional: Validate template before deploy
Test-AzResourceGroupDeployment `
  -ResourceGroupName $resourceGroupName `
  -TemplateFile $templatePath `
  -TemplateParameterObject $parameters `
  -ErrorAction Stop

# =========================
# 7) Deploy
# =========================
$deploymentName = "la-ssl-expiry-$(Get-Date -Format 'yyyyMMddHHmmss')"

New-AzResourceGroupDeployment `
  -Name $deploymentName `
  -ResourceGroupName $resourceGroupName `
  -TemplateFile $templatePath `
  -TemplateParameterObject $parameters `
  -Mode Incremental `
  -Verbose -ErrorAction Stop

Write-Host "`nDeployment complete."

# =========================
# 8) Grant Key Vault permissions to the Logic App's Managed Identity
# =========================
# Fetch logic app identity principalId
$laRes = Get-AzResource -ResourceGroupName $resourceGroupName -ResourceType "Microsoft.Logic/workflows" -Name $logicAppName -ExpandProperties
$principalId = $laRes.Identity.PrincipalId
if (-not $principalId) {
  throw "Managed Identity not found on '$logicAppName'."
}

# Get Key Vault
$kv = Get-AzKeyVault -VaultName $kvName -ErrorAction Stop

if ($kv.EnableRbacAuthorization) {
    # RBAC model: assign Key Vault Secrets User
    Write-Host "Key Vault uses RBAC. Assigning role 'Key Vault Secrets User' to MI..."
    $role = Get-AzRoleDefinition -Name "Key Vault Secrets User"
    New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionId $role.Id -Scope $kv.ResourceId -ErrorAction SilentlyContinue | Out-Null
} else {
    # Access policy model
    Write-Host "Key Vault uses Access Policies. Granting Get/List on secrets to MI..."
    Set-AzKeyVaultAccessPolicy -VaultName $kvName -ObjectId $principalId -PermissionsToSecrets get,list -ErrorAction Stop | Out-Null
}

Write-Host "Access granted."

Write-Host "`nNEXT STEPS:"
Write-Host "1) In the Resource Group > Connections:"
Write-Host "   - Open 'office365' and click 'Authorize' (sign in with a sender account)."
Write-Host "2) Run the workflow and confirm emails are sent."