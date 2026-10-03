# Prism installer for Windows.
#
#   irm https://raw.githubusercontent.com/twistedsignal/prism/main/install.ps1 | iex
#
# To uninstall:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/twistedsignal/prism/main/install.ps1))) -Uninstall
#
# Environment overrides:
#   PRISM_VERSION      install this version instead of the latest release (e.g. 1.0.0)
#   PRISM_SOURCE       install from a local checkout (uses backend\ and build\Prism.rbxm) instead of downloading
#   PRISM_BLENDER      path to blender.exe
#   PRISM_PLUGINS_DIR  Studio Plugins folder to install into

param([switch]$Uninstall)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Invoke-PrismInstaller {
	param([bool]$Remove)

	$repo = "twistedsignal/prism"
	$credentialsUrl = "https://create.roblox.com/dashboard/credentials?activeTab=ApiKeysTab"
	$ravenTarball = "https://github.com/twistedsignal/raven/archive/refs/tags/v0.3.0.tar.gz"
	$port = 47821
	$installDir = Join-Path $env:LOCALAPPDATA "Prism"
	$pluginsDir = if ($env:PRISM_PLUGINS_DIR) { $env:PRISM_PLUGINS_DIR } else { Join-Path $env:LOCALAPPDATA "Roblox\Plugins" }

	function Write-Step([string]$Text) { Write-Host ""; Write-Host $Text -ForegroundColor Cyan }
	function Write-Ok([string]$Text) { Write-Host $Text -ForegroundColor Green }
	function Write-Warn([string]$Text) { Write-Host $Text -ForegroundColor Yellow }
	function Stop-Install([string]$Text) {
		Write-Host ""
		Write-Host $Text -ForegroundColor Red
		throw "Prism installation stopped."
	}

	# ------------------------------------------------------------
	# Version
	# ------------------------------------------------------------

	$version = $env:PRISM_VERSION
	if (-not $version -and $env:PRISM_SOURCE) {
		$wally = Get-Content -Raw -LiteralPath (Join-Path $env:PRISM_SOURCE "wally.toml")
		if ($wally -match '(?m)^\s*version\s*=\s*"(?<v>[^"]+)"') { $version = $Matches.v }
	}
	if (-not $version) {
		try {
			$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest"
			$version = $release.tag_name
		} catch {
			Stop-Install "Could not find the latest Prism release. Check your internet connection."
		}
	}
	$version = $version.TrimStart("v")

	$action = if ($Remove) { "Uninstall" } else { "Installation" }
	Write-Host "Prism v$version $action..."

	# ------------------------------------------------------------
	# Blender
	# ------------------------------------------------------------

	$blender = $null
	if ($env:PRISM_BLENDER) {
		$blender = $env:PRISM_BLENDER
	} elseif (Get-Command blender -ErrorAction SilentlyContinue) {
		$blender = (Get-Command blender).Source
	} else {
		$roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA "Programs")) | Where-Object { $_ }
		$found = foreach ($root in $roots) {
			Get-ChildItem -Path (Join-Path $root "Blender Foundation") -Directory -ErrorAction SilentlyContinue |
				ForEach-Object { Join-Path $_.FullName "blender.exe" } |
				Where-Object { Test-Path $_ }
		}
		# Newest version first, by the number in "Blender 4.2".
		$blender = $found | Sort-Object {
			if ($_ -match 'Blender (\d+)\.(\d+)') { [int]$Matches[1] * 1000 + [int]$Matches[2] } else { 0 }
		} -Descending | Select-Object -First 1
		if (-not $blender) {
			$steam = Join-Path ${env:ProgramFiles(x86)} "Steam\steamapps\common\Blender\blender.exe"
			if (Test-Path $steam) { $blender = $steam }
		}
	}

	if (-not $blender) {
		if ($Remove) {
			Write-Warn "Blender was not found, so the startup entry can't be removed automatically."
		} else {
			Write-Host ""
			Write-Host "You do not have Blender installed! Please install it." -ForegroundColor Red
			Write-Host "Download it from https://www.blender.org/download/ and run this installer again."
			return
		}
	}

	if (-not $Remove) {
		$versionLine = (& $blender --version 2>$null | Select-Object -First 1)
		if ($versionLine -notmatch '^Blender (\d+)\.(\d+)') {
			Stop-Install "Could not run Blender ($blender). Set PRISM_BLENDER to blender.exe and try again."
		}
		$major = [int]$Matches[1]
		$minor = [int]$Matches[2]
		if ($major -lt 4 -or ($major -eq 4 -and $minor -lt 2)) {
			Stop-Install "Prism needs Blender 4.2 or newer; found $major.$minor. Please update Blender."
		}
		Write-Host ""
		Write-Ok "Blender is installed, continuing..."
	}

	# ------------------------------------------------------------
	# Uninstall
	# ------------------------------------------------------------

	if ($Remove) {
		Write-Step "Removing startup script..."
		$main = Join-Path $installDir "backend\main.py"
		if ($blender -and (Test-Path $main)) {
			& $blender --background --factory-startup --python $main -- uninstall *> $null
		}
		Write-Step "Removing backend..."
		Remove-Item -Recurse -Force (Join-Path $installDir "backend") -ErrorAction SilentlyContinue
		Write-Step "Removing local Roblox plugin..."
		Remove-Item -Force (Join-Path $pluginsDir "Prism.rbxm") -ErrorAction SilentlyContinue
		Write-Host ""
		Write-Ok "Prism has been uninstalled. Raven, your settings and presets were left in place."
		return
	}

	# ------------------------------------------------------------
	# Raven
	# ------------------------------------------------------------

	$node = Get-Command node -ErrorAction SilentlyContinue
	if (-not $node) {
		Stop-Install "Raven needs Node.js 20 or newer. Install it from https://nodejs.org and run this installer again."
	}
	$nodeVersion = (& node --version)
	if ($nodeVersion -notmatch '^v(\d+)' -or [int]$Matches[1] -lt 20) {
		Stop-Install "Raven needs Node.js 20 or newer; found $nodeVersion. Update it from https://nodejs.org."
	}

	function Find-Raven {
		$command = Get-Command raven.cmd -ErrorAction SilentlyContinue
		if ($command) { return $command.Source }
		$shim = Join-Path $env:APPDATA "npm\raven.cmd"
		if (Test-Path $shim) { return $shim }
		return $null
	}

	$raven = Find-Raven
	if (-not $raven -or -not ((& $raven asset download --help 2>$null) -match "--output")) {
		Write-Host ""
		Write-Host "Installing Raven v0.3.0 asset download support..." -ForegroundColor Yellow
		& npm install -g $ravenTarball *> $null
		if ($LASTEXITCODE -ne 0) { Stop-Install "Could not install Raven with npm." }
		$raven = Find-Raven
		if (-not $raven) { Stop-Install "Raven was installed but couldn't be found. Make sure npm's global folder is on your PATH." }
		if (-not ((& $raven asset download --help 2>$null) -match "--output")) { Stop-Install "Raven asset download support is still unavailable. Check your npm installation." }
		Write-Host ""
		Write-Ok "Raven has been installed."
	}

	# ------------------------------------------------------------
	# API key
	# ------------------------------------------------------------

	$ravenDir = if ($env:RAVEN_CONFIG_DIR) { $env:RAVEN_CONFIG_DIR } else { Join-Path $env:APPDATA "raven" }
	$credentials = Join-Path $ravenDir "credentials.json"

	# Returns @{ Ok; Reason; Name; OwnerId } for a key.
	function Test-ApiKey([string]$Key) {
		if (-not $Key) { return @{ Ok = $false; Reason = "The key is empty." } }
		$body = @{ apiKey = $Key } | ConvertTo-Json -Compress
		try {
			$info = Invoke-RestMethod -Method Post -Uri "https://apis.roblox.com/api-keys/v1/introspect" `
				-ContentType "application/json" -Body $body
		} catch {
			$status = $null
			if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
			if ($status -in 400, 401, 403) {
				return @{ Ok = $false; Reason = "That key is invalid. Make sure you copied the whole key." }
			}
			if ($status) { return @{ Ok = $false; Reason = "Roblox returned HTTP $status. Try again in a moment." } }
			return @{ Ok = $false; Reason = "Could not reach Roblox. Check your internet connection." }
		}
		if ($info.enabled -eq $false) { return @{ Ok = $false; Reason = "That key is disabled. Enable it on the Creator Dashboard." } }
		if ($info.expired) { return @{ Ok = $false; Reason = "That key has expired. Create a new one." } }
		$canWrite = $false
		$canRead = $false
		$canDownload = $false
		foreach ($scope in @($info.scopes)) {
			if ($scope -is [string]) {
				if ($scope -match '^assets?:write$') { $canWrite = $true }
				if ($scope -match '^assets?:read$') { $canRead = $true }
				if ($scope -match '^legacy-asset:manage$') { $canDownload = $true }
			} else {
				if ($scope.name -match '^assets?$') {
					$canWrite = $canWrite -or (@($scope.operations) -contains "write")
					$canRead = $canRead -or (@($scope.operations) -contains "read")
				}
				if ($scope.name -eq 'legacy-asset') { $canDownload = $canDownload -or (@($scope.operations) -contains "manage") }
			}
		}
		if (-not $canWrite -or -not $canRead) {
			return @{ Ok = $false; Reason = "That key needs Assets Read and Write access. Edit the key and add them." }
		}
		if (-not $canDownload) { return @{ Ok = $false; Reason = "That key needs Legacy Assets Manage access. Edit the existing key and add it." } }
		return @{ Ok = $true; Name = [string]$info.name; OwnerId = [string]$info.authorizedUserId }
	}

	$apiKey = $null
	$keyInfo = $null
	$existing = $null
	if (Test-Path $credentials) {
		try { $existing = Get-Content -Raw -LiteralPath $credentials | ConvertFrom-Json } catch { $existing = $null }
	}
	if ($existing -and $existing.apiKey) {
		$check = Test-ApiKey $existing.apiKey
		if ($check.Ok) {
			Write-Host ""
			$label = if ($check.Name) { " ($($check.Name))" } else { "" }
			$answer = Read-Host "Use existing Raven key$label? [Y/n]"
			if ($answer -notmatch '^[Nn]') {
				$apiKey = $existing.apiKey
				$keyInfo = $check
			}
		} else {
			Write-Host $check.Reason -ForegroundColor Yellow
		}
	}

	if (-not $apiKey) {
		Write-Host ""
		Read-Host "Press enter to open $credentialsUrl" | Out-Null
		Start-Process $credentialsUrl
		Write-Host ""
		Write-Host "Create an API key with the following permissions:"
		Write-Host ""
		Write-Host "  Make sure the dashboard is on your personal account, not a group."
		Write-Host "  1. Click Create API Key and give it a name, like Prism."
		Write-Host "  2. Under Access Permissions, add the API System Assets."
		Write-Host "  3. Give it Read and Write."
		Write-Host "  4. Add Legacy Assets with Manage access."
		Write-Host "  5. Save the key, then copy it. Existing users can edit their current key."
		Write-Host "  A personal key can upload to any group you have access to." -ForegroundColor DarkGray
		Write-Host ""
		Read-Host "Press enter when done." | Out-Null
		while ($true) {
			Write-Host ""
			$secure = Read-Host "Enter your API key" -AsSecureString
			$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
			try { $candidate = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer).Trim() }
			finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
			Write-Host ""
			Write-Host "Validating..."
			$check = Test-ApiKey $candidate
			if ($check.Ok) {
				$apiKey = $candidate
				$keyInfo = $check
				break
			}
			Write-Host $check.Reason -ForegroundColor Red
		}

	}
	$features = @()
	if ($existing -and $existing.features) { $features = @($existing.features) }
	if ($features -notcontains "asset") { $features += "asset" }
	if ($features -notcontains "asset-download") { $features += "asset-download" }
	$saved = [ordered]@{ apiKey = $apiKey }
	if ($keyInfo.Name) { $saved.name = $keyInfo.Name }
	if ($keyInfo.OwnerId) { $saved.ownerId = $keyInfo.OwnerId }
	# Older Raven logins without a feature list enable all commands.
	if (-not $existing -or -not $existing.apiKey -or $null -ne $existing.features) { $saved.features = $features }
	$saved.savedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
	New-Item -ItemType Directory -Force -Path $ravenDir | Out-Null
	# Node can't parse JSON with a BOM, so write UTF-8 without one.
	[IO.File]::WriteAllText($credentials, ($saved | ConvertTo-Json) + "`n", (New-Object Text.UTF8Encoding $false))
	$apiKey = $null
	Write-Host ""
	Write-Ok "Valid API key to upload images!"

	# ------------------------------------------------------------
	# Backend
	# ------------------------------------------------------------

	Write-Step "Installing backend..."
	New-Item -ItemType Directory -Force -Path $installDir | Out-Null
	$staging = Join-Path ([IO.Path]::GetTempPath()) ("prism-" + [Guid]::NewGuid())
	New-Item -ItemType Directory -Force -Path $staging | Out-Null
	try {
		if ($env:PRISM_SOURCE) {
			Copy-Item -Recurse (Join-Path $env:PRISM_SOURCE "backend") (Join-Path $staging "backend")
			Copy-Item (Join-Path $env:PRISM_SOURCE "build\Prism.rbxm") (Join-Path $staging "Prism.rbxm")
		} else {
			$base = "https://github.com/$repo/releases/download/v$version"
			try {
				Invoke-WebRequest "$base/prism-backend.zip" -OutFile (Join-Path $staging "backend.zip") -UseBasicParsing
				Invoke-WebRequest "$base/Prism.rbxm" -OutFile (Join-Path $staging "Prism.rbxm") -UseBasicParsing
			} catch {
				Stop-Install "Could not download Prism v$version."
			}
			Expand-Archive -Path (Join-Path $staging "backend.zip") -DestinationPath $staging -Force
		}
		Get-ChildItem -Path (Join-Path $staging "backend") -Recurse -Directory -Filter "__pycache__" |
			Remove-Item -Recurse -Force
		[IO.File]::WriteAllText((Join-Path $staging "backend\VERSION"), "$version`n", (New-Object Text.UTF8Encoding $false))
		Remove-Item -Recurse -Force (Join-Path $installDir "backend") -ErrorAction SilentlyContinue
		Move-Item (Join-Path $staging "backend") (Join-Path $installDir "backend")

		# ------------------------------------------------------------
		# Startup
		# ------------------------------------------------------------

		Write-Step "Installing startup script.."
		$arguments = @("--background", "--factory-startup", "--python", (Join-Path $installDir "backend\main.py"), "--",
			"install", "--raven", $raven, "--blender", $blender)
		if ($keyInfo -and $keyInfo.OwnerId) { $arguments += @("--creator", "user:$($keyInfo.OwnerId)") }
		& $blender @arguments *> $null
		if ($LASTEXITCODE -ne 0) {
			Stop-Install "Could not install the startup script. Run the installer again or check your Blender install."
		}

		$started = $false
		for ($i = 0; $i -lt 30; $i++) {
			try {
				Invoke-RestMethod -Uri "http://127.0.0.1:$port/status" -Headers @{ "X-Prism" = "1" } | Out-Null
				$started = $true
				break
			} catch {
				Start-Sleep -Milliseconds 500
			}
		}
		if (-not $started) {
			Write-Warn "The backend didn't respond yet. Check $(Join-Path $env:LOCALAPPDATA 'Prism\prism.log')."
		}

		# ------------------------------------------------------------
		# Plugin
		# ------------------------------------------------------------

		Write-Step "Installing local Roblox plugin..."
		New-Item -ItemType Directory -Force -Path $pluginsDir | Out-Null
		Copy-Item -Force (Join-Path $staging "Prism.rbxm") (Join-Path $pluginsDir "Prism.rbxm")
		Write-Host "  $(Join-Path $pluginsDir 'Prism.rbxm')" -ForegroundColor DarkGray
	} finally {
		Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
	}

	Write-Host ""
	Write-Ok "Prism v$version has been installed!"
	Write-Host "Restart Roblox Studio and open Prism from the Plugins tab."
}

try {
	Invoke-PrismInstaller -Remove ([bool]$Uninstall)
} catch {
	if ($_.Exception.Message -ne "Prism installation stopped.") {
		Write-Host $_.Exception.Message -ForegroundColor Red
	}
}
