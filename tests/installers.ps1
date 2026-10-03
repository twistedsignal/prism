# Run: pwsh -NoProfile -File tests/installers.ps1
$tokens = $null
$errors = $null
$path = Join-Path $PSScriptRoot '../install.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-ApiKey' }, $true)
Invoke-Expression $function.Extent.Text
function Invoke-RestMethod { return $script:response }
$script:response = @{ enabled = $true; scopes = @('asset:read', 'asset:write', 'legacy-asset:manage') }
if (-not (Test-ApiKey 'test-key').Ok) { throw 'Expected complete permissions to pass' }
$script:response.scopes = @('asset:read', 'asset:write')
if ((Test-ApiKey 'test-key').Ok) { throw 'Missing Legacy Assets permission should fail' }
$script:response.scopes = @('asset:write', 'legacy-asset:manage')
if ((Test-ApiKey 'test-key').Ok) { throw 'Missing Read permission should fail' }
$script:response.scopes = @(@{name='assets';operations=@('Read','Write')}, @{name='legacy-asset';operations=@('Manage')})
if (-not (Test-ApiKey 'test-key').Ok) { throw 'Expected object-form permissions to pass' }
'PowerShell installer checks passed'
