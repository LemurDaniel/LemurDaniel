# NOTE:
#   Requires: PowerShell 7 and a GitHub token in $env:GITHUB_TOKEN (falls back to 'gh auth token').
#
#   ./.scripts/Update-PinCard.ps1 -Verbose
#
#   Reads the pinned repositories of the owner in '.github/pin-cards.json', renders one static
#   SVG pin card per repository into 'assets/pin.<repository>.svg' and rewrites the block between
#   the PIN-CARDS markers in the README. Replaces the paused github-readme-stats.vercel.app instance.

<#
.SYNOPSIS
    Renders the pinned repositories of a GitHub user as SVG cards and links them in the README.

.DESCRIPTION
    Reads name, description, primary language, stars and forks of each pinned repository
    from the GitHub GraphQL API and writes a pin card in the Tokyo Night theme.
    Cards of repositories that are no longer pinned are removed.
    A file is only rewritten when its content changed, so the workflow commits real changes only.

.EXAMPLE
    Render the cards and update the README:

    PS> ./.scripts/Update-PinCard.ps1 -Verbose
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    <#
    [Optional]
    The config with the owner of the pinned repositories. Default is '.github/pin-cards.json'.
    #>
    [Parameter(
        Mandatory = $false
    )]
    [System.String]
    $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../.github/pin-cards.json'),

    <#
    [Optional]
    The folder the SVG files are written to. Default is 'assets'.
    #>
    [Parameter(
        Mandatory = $false
    )]
    [System.String]
    $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../assets'),

    <#
    [Optional]
    The README with the PIN-CARDS markers. Default is 'README.md'.
    #>
    [Parameter(
        Mandatory = $false
    )]
    [System.String]
    $ReadmePath = (Join-Path -Path $PSScriptRoot -ChildPath '../README.md')
)

# ===========================================================================
# ==============================   SETTINGS   ===============================
# ===========================================================================
#
#   Layout   Card size, text wrapping, Tokyo Night colors and Octicon paths.
#            Change these to restyle all cards at once.
#   GitHub   The GraphQL query for the pinned repositories and the README
#            markers that frame the generated block.
#

# ---------------------------------------------------------------------------
# Layout

$CARD_WIDTH            = 400
$DESCRIPTION_MAX_CHARS = 55   # characters per line at 13px inside the card width
$DESCRIPTION_MAX_LINES = 3
$LINE_HEIGHT           = 18

# Tokyo Night colors, same as the former '&theme=tokyonight'.
$Theme = @{
    Background = '#1a1b27'
    Title      = '#70a5fd'
    Text       = '#38bdae'
    Icon       = '#bf91f3'
}

# Octicons (repo, star, fork), 16x16 viewBox.
$Icon = @{
    Repo = 'M2 2.5A2.5 2.5 0 014.5 0h8.75a.75.75 0 01.75.75v12.5a.75.75 0 01-.75.75h-2.5a.75.75 0 110-1.5h1.75v-2h-8a1 1 0 00-.714 1.7.75.75 0 01-1.072 1.05A2.495 2.495 0 012 11.5v-9zm10.5-1V9h-8c-.356 0-.694.074-1 .208V2.5a1 1 0 011-1h8zM5 12.25v3.25a.25.25 0 00.4.2l1.45-1.087a.25.25 0 01.3 0L8.6 15.7a.25.25 0 00.4-.2v-3.25a.25.25 0 00-.25-.25h-3.5a.25.25 0 00-.25.25z'
    Star = 'M8 .25a.75.75 0 01.673.418l1.882 3.815 4.21.612a.75.75 0 01.416 1.279l-3.046 2.97.719 4.192a.75.75 0 01-1.088.791L8 12.347l-3.766 1.98a.75.75 0 01-1.088-.79l.72-4.194L.818 6.374a.75.75 0 01.416-1.28l4.21-.611L7.327.668A.75.75 0 018 .25zm0 2.445L6.615 5.5a.75.75 0 01-.564.41l-3.097.45 2.24 2.184a.75.75 0 01.216.664l-.528 3.084 2.769-1.456a.75.75 0 01.698 0l2.77 1.456-.53-3.084a.75.75 0 01.216-.664l2.24-2.183-3.096-.45a.75.75 0 01-.564-.41L8 2.694v.001z'
    Fork = 'M5 3.25a.75.75 0 11-1.5 0 .75.75 0 011.5 0zm0 2.122a2.25 2.25 0 10-1.5 0v.878A2.25 2.25 0 005.75 8.5h1.5v2.128a2.251 2.251 0 101.5 0V8.5h1.5a2.25 2.25 0 002.25-2.25v-.878a2.25 2.25 0 10-1.5 0v.878a.75.75 0 01-.75.75h-4.5A.75.75 0 015 6.25v-.878zm3.75 7.378a.75.75 0 11-1.5 0 .75.75 0 011.5 0zm3-8.75a.75.75 0 100-1.5.75.75 0 000 1.5z'
}

# ---------------------------------------------------------------------------
# GitHub

# GitHub allows at most 6 pinned items.
$PINNED_QUERY = @'
query ($owner: String!) {
  user(login: $owner) {
    pinnedItems(first: 6, types: REPOSITORY) {
      nodes {
        ... on Repository {
          name
          url
          description
          stargazerCount
          forkCount
          primaryLanguage { name color }
        }
      }
    }
  }
}
'@

# The README block between these markers is generated, everything outside stays untouched.
$README_MARKER_START = '<!-- PIN-CARDS:START -->'
$README_MARKER_END   = '<!-- PIN-CARDS:END -->'

# ===========================================================================
# ===============================   HELPERS   ===============================
# ===========================================================================
#
#   Split-TextLine       Wraps the description at word boundaries, max. 3 lines.
#   Format-Count         Shortens counts like GitHub does (1.2k).
#   Set-ChangedContent   Writes a file only when its content differs.
#   Get-PinCardSvg       Builds the SVG of one card: header, description, footer.
#

# Splits a text into lines of at most $MaxChars, cut at word boundaries. The last line gets '…' when text is left over.
function Split-TextLine {
    param ([System.String] $Text, [System.Int32] $MaxChars, [System.Int32] $MaxLines)

    $lines = [System.Collections.Generic.List[System.String]]::new()
    $line  = ''
    foreach ($word in ($Text -split '\s+')) {
        if ($line.Length -GT 0 -AND ($line.Length + 1 + $word.Length) -GT $MaxChars) {
            $lines.Add($line)
            $line = $word
        }
        else {
            $line = ($line.Length -GT 0) ? "$line $word" : $word
        }
    }
    if ($line.Length -GT 0) {
        $lines.Add($line)
    }

    if ($lines.Count -LE $MaxLines) {
        return $lines.ToArray()
    }

    $visibleLines = $lines.GetRange(0, $MaxLines).ToArray()
    $visibleLines[-1] = $visibleLines[-1].Substring(0, [System.Math]::Min($visibleLines[-1].Length, $MaxChars - 1)) + '…'
    return $visibleLines
}

# Formats counts like GitHub does: 999, 1.2k, 15k.
function Format-Count {
    param ([System.Int32] $Count)

    if ($Count -LT 1000) {
        return "$Count"
    }
    return [System.String]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.#}k', $Count / 1000)
}

# Writes a file only when its content differs, so unchanged files produce no commit.
function Set-ChangedContent {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param ([System.String] $Path, [System.String] $Value)

    if ((Test-Path -Path $Path) -AND (Get-Content -Path $Path -Raw) -EQ $Value) {
        Write-Verbose "[Update-PinCard] '$Path' unchanged -> skipping."
        return
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Write file')) {
        Write-Verbose "[Update-PinCard] '$Path' changed -> writing."
        Set-Content -Path $Path -Value $Value -NoNewline
    }
}

function Get-PinCardSvg {
    param ([System.Object] $Repository)

    $escape = { param ($text) [System.Security.SecurityElement]::Escape($text) }

    $descriptionLines = Split-TextLine -Text ($Repository.description ?? 'No description provided') -MaxChars $DESCRIPTION_MAX_CHARS -MaxLines $DESCRIPTION_MAX_LINES
    $descriptionSpans = for ($index = 0; $index -LT $descriptionLines.Count; $index++) {
        "<tspan x=`"25`" dy=`"$(($index -EQ 0) ? 0 : $LINE_HEIGHT)`">$(& $escape $descriptionLines[$index])</tspan>"
    }

    # The footer always sits below the maximum description lines, so all cards share one height in the grid.
    $footerY    = 65 + ($DESCRIPTION_MAX_LINES * $LINE_HEIGHT) + 8
    $cardHeight = $footerY + 22

    # Footer items are laid out from left to right: language (optional), stars, forks.
    $footer  = [System.Collections.Generic.List[System.String]]::new()
    $footerX = 25
    if ($null -NE $Repository.primaryLanguage) {
        $language = $Repository.primaryLanguage
        $footer.Add("<g transform=`"translate($footerX, 0)`"><circle cx=`"6`" cy=`"-4`" r=`"6`" fill=`"$($language.color ?? $Theme.Text)`"/><text x=`"18`" class=`"meta`">$(& $escape $language.name)</text></g>")
        $footerX += 18 + ($language.name.Length * 6.5) + 16
    }
    foreach ($stat in @(
            @{ Path = $Icon.Star; Value = Format-Count $Repository.stargazerCount }
            @{ Path = $Icon.Fork; Value = Format-Count $Repository.forkCount }
        )) {
        $footer.Add("<g transform=`"translate($footerX, 0)`"><svg y=`"-13`" width=`"16`" height=`"16`" viewBox=`"0 0 16 16`"><path fill-rule=`"evenodd`" fill=`"$($Theme.Icon)`" d=`"$($stat.Path)`"/></svg><text x=`"22`" class=`"meta`">$($stat.Value)</text></g>")
        $footerX += 22 + ($stat.Value.Length * 7) + 20
    }

    return @"
<svg xmlns="http://www.w3.org/2000/svg" width="$CARD_WIDTH" height="$cardHeight" viewBox="0 0 $CARD_WIDTH $cardHeight" fill="none" role="img" aria-labelledby="title">
  <title id="title">$(& $escape $Repository.name)</title>
  <style>
    .header { font: 600 18px 'Segoe UI', Ubuntu, Sans-Serif; fill: $($Theme.Title); }
    .description { font: 400 13px 'Segoe UI', Ubuntu, Sans-Serif; fill: $($Theme.Text); }
    .meta { font: 400 12px 'Segoe UI', Ubuntu, Sans-Serif; fill: $($Theme.Text); }
  </style>
  <rect x="0.5" y="0.5" rx="10" width="$($CARD_WIDTH - 1)" height="$($cardHeight - 1)" fill="$($Theme.Background)"/>
  <svg x="25" y="21" width="16" height="16" viewBox="0 0 16 16"><path fill-rule="evenodd" fill="$($Theme.Icon)" d="$($Icon.Repo)"/></svg>
  <text x="50" y="35" class="header">$(& $escape $Repository.name)</text>
  <text x="25" y="65" class="description">$($descriptionSpans -join '')</text>
  <g transform="translate(0, $footerY)">$($footer -join '')</g>
</svg>
"@
}

# ===========================================================================
# ====================   RENDER PINNED REPOS AS CARDS   =====================
# ===========================================================================
#
#   1. Config        Loads the owner and resolves the GitHub token.
#   2. Validations   Fails early on a missing owner, token or README marker.
#   3. Read pinned   Fetches the pinned repositories via GraphQL (max. 6).
#                    An empty result stops the run instead of wiping the README.
#   4. Render cards  Writes one SVG per repository and removes cards that are
#                    no longer pinned.
#   5. README        Replaces the block between the PIN-CARDS markers with one
#                    linked card per repository.
#
#   Files are only written when their content changed, so an unchanged run
#   leaves the working tree clean and the workflow commits nothing.
#

# ---------------------------------------------------------------------------
# Config

$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

# Order of precedence: environment variable > GitHub CLI
$Token = @(
    $env:GITHUB_TOKEN               # environment variable (set by the workflow)
    (Get-Command gh -ErrorAction SilentlyContinue) ? (gh auth token) : $null   # GitHub CLI
) | Where-Object { -NOT [System.String]::IsNullOrEmpty($_) } | Select-Object -First 1

# ---------------------------------------------------------------------------
# Validations

$Readme = Get-Content -Path $ReadmePath -Raw
if ([System.String]::IsNullOrEmpty($Config.owner)) {
    throw [System.ArgumentException]::new("Config '$ConfigPath' must contain an 'owner'.")
}
if ($null -EQ $Token) {
    throw [System.InvalidOperationException]::new("A GitHub token must be set in `$env:GITHUB_TOKEN or available via 'gh auth token'.")
}
if (-NOT $Readme.Contains($README_MARKER_START) -OR -NOT $Readme.Contains($README_MARKER_END)) {
    throw [System.InvalidOperationException]::new("README '$ReadmePath' must contain the markers '$README_MARKER_START' and '$README_MARKER_END'.")
}

# ---------------------------------------------------------------------------
# Read pinned repositories

$RequestConfig = @{
    Method      = 'Post'
    Uri         = 'https://api.github.com/graphql'
    Headers     = @{ Authorization = "Bearer $Token" }
    ContentType = 'application/json'
    Body        = @{ query = $PINNED_QUERY; variables = @{ owner = $Config.owner } } | ConvertTo-Json -Depth 5
}
$response = Invoke-RestMethod @RequestConfig

if ($null -NE $response.errors) {
    throw [System.InvalidOperationException]::new("User '$($Config.owner)' must exist and be readable: $($response.errors.message -join '; ')")
}

$PinnedRepositories = $response.data.user.pinnedItems.nodes
Write-Verbose "[Update-PinCard] Found $($PinnedRepositories.Count) pinned repositories: $($PinnedRepositories.name -join ', ')."

# An empty result would wipe the README block, which is almost always an API or token problem.
if ($PinnedRepositories.Count -EQ 0) {
    throw [System.InvalidOperationException]::new("User '$($Config.owner)' must have at least one pinned repository.")
}

# ---------------------------------------------------------------------------
# Render cards

$null = New-Item -ItemType Directory -Path $OutputPath -Force

foreach ($repository in $PinnedRepositories) {
    $filePath = Join-Path -Path $OutputPath -ChildPath "pin.$($repository.name).svg"
    Set-ChangedContent -Path $filePath -Value (Get-PinCardSvg -Repository $repository)
}

# Remove cards of repositories that are no longer pinned.
$pinnedFileNames = $PinnedRepositories | ForEach-Object { "pin.$($_.name).svg" }
foreach ($staleCard in (Get-ChildItem -Path $OutputPath -Filter 'pin.*.svg' | Where-Object -Property Name -NotIn -Value $pinnedFileNames)) {
    if ($PSCmdlet.ShouldProcess($staleCard.FullName, 'Remove unpinned card')) {
        Write-Verbose "[Update-PinCard] '$($staleCard.Name)' is no longer pinned -> removing."
        Remove-Item -Path $staleCard.FullName
    }
}

# ---------------------------------------------------------------------------
# Update README

# The README uses relative paths, so the links work on GitHub and locally.
$relativeOutputPath = [System.IO.Path]::GetRelativePath((Split-Path -Path $ReadmePath -Parent), $OutputPath) -replace '\\', '/'
$cardLines = $PinnedRepositories | ForEach-Object {
    "<a href=`"$($_.url)`"><img width=`"49%`" src=`"./$relativeOutputPath/pin.$($_.name).svg`" alt=`"$($_.name)`"/></a>"
}

$markerPattern = "(?s)$([System.Text.RegularExpressions.Regex]::Escape($README_MARKER_START)).*?$([System.Text.RegularExpressions.Regex]::Escape($README_MARKER_END))"
$cardBlock     = (@($README_MARKER_START) + $cardLines + @($README_MARKER_END)) -join "`n"
$readmeUpdated = [System.Text.RegularExpressions.Regex]::Replace($Readme, $markerPattern, { $cardBlock })

Set-ChangedContent -Path $ReadmePath -Value $readmeUpdated