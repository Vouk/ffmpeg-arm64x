<#
    Tests fuer scripts/merge-arm64x.ps1 (ARM64X-Pure-Forwarder).

    Geprueft werden die reinen Funktionen: Umwandlung einer FFmpeg-.def in eine
    Forwarder-.def und die Zusammenstellung des link.exe-Aufrufs. Die echte
    Toolchain (cl/link) laeuft nur auf CI; hier wird nur die Logik verifiziert.
#>

BeforeAll {
    $script:Merge = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts/merge-arm64x.ps1"
    . $script:Merge -Arm64Dir x -Arm64ecDir x -Arm64LibDir x -Arm64ecLibDir x -OutputDir x -DryRun 6>$null 2>$null

    $script:Lister = { param($d) Get-ChildItem -LiteralPath $d -Filter *.dll -File | ForEach-Object { $_.BaseName } }

    function New-Layout {
        param([string[]] $Libs = @("avcodec-62", "avutil-60"))
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N").Substring(0,8))
        foreach ($d in "a64/bin","a64ec/bin","a64/lib","a64ec/lib","out") {
            New-Item -ItemType Directory -Force -Path (Join-Path $root $d) | Out-Null
        }
        foreach ($lib in $Libs) {
            Set-Content -Path (Join-Path $root "a64/bin/$lib.dll")   -Value "x"
            Set-Content -Path (Join-Path $root "a64ec/bin/$lib.dll") -Value "x"
            Set-Content -Path (Join-Path $root "a64/lib/$lib.def")   -Value "EXPORTS`n    sym1"
            Set-Content -Path (Join-Path $root "a64ec/lib/$lib.def") -Value "EXPORTS`n    sym1"
            Set-Content -Path (Join-Path $root "a64/lib/$lib.lib")   -Value "x"
            Set-Content -Path (Join-Path $root "a64ec/lib/$lib.lib") -Value "x"
        }
        return [pscustomobject]@{
            Root          = $root
            Arm64Dir      = (Join-Path $root "a64/bin")
            Arm64ecDir    = (Join-Path $root "a64ec/bin")
            Arm64LibDir   = (Join-Path $root "a64/lib")
            Arm64ecLibDir = (Join-Path $root "a64ec/lib")
            OutputDir     = (Join-Path $root "out")
        }
    }

    function Get-Plan {
        param([pscustomobject] $Layout)
        Get-Arm64xForwarderPlan -Arm64Dir $Layout.Arm64Dir -Arm64ecDir $Layout.Arm64ecDir `
            -Arm64LibDir $Layout.Arm64LibDir -Arm64ecLibDir $Layout.Arm64ecLibDir `
            -OutputDir $Layout.OutputDir -LinkExe link.exe -ClExe cl.exe -DllLister $script:Lister
    }
}

Describe "ConvertTo-ForwarderDef" {
    It "leitet jedes Symbol auf das Zielmodul weiter" {
        $def = "EXPORTS`n    avcodec_open2`n    avcodec_close"
        $r = ConvertTo-ForwarderDef -DefContent $def -ForwardTo "avcodec-62.arm64"
        ($r -split "`n") | Should -Contain "    avcodec_open2=avcodec-62.arm64.avcodec_open2"
        ($r -split "`n") | Should -Contain "    avcodec_close=avcodec-62.arm64.avcodec_close"
    }

    It "behaelt die EXPORTS-Zeile und Kommentare" {
        $def = "EXPORTS`n    ; hint`n    sym"
        $r = ConvertTo-ForwarderDef -DefContent $def -ForwardTo "m.arm64"
        ($r -split "`n")[0] | Should -Be "EXPORTS"
        $r | Should -Match "; hint"
    }

    It "entfernt Ordinale und Attribute nach dem Symbolnamen" {
        $def = "EXPORTS`n    av_malloc @7`n    av_free DATA"
        $r = ConvertTo-ForwarderDef -DefContent $def -ForwardTo "avutil-60.arm64ec"
        ($r -split "`n") | Should -Contain "    av_malloc=avutil-60.arm64ec.av_malloc"
        ($r -split "`n") | Should -Contain "    av_free=avutil-60.arm64ec.av_free"
        $r | Should -Not -Match "@7"
        $r | Should -Not -Match "DATA"
    }

    It "laesst bereits weitergeleitete Zeilen unveraendert" {
        $def = "EXPORTS`n    foo=other.foo"
        (ConvertTo-ForwarderDef -DefContent $def -ForwardTo "m.arm64") | Should -Match ([regex]::Escape("foo=other.foo"))
    }
}

Describe "Get-Arm64xForwarderPlan" {
    It "erzeugt je gepaarter DLL einen Forwarder-Eintrag" {
        $plan = Get-Plan (New-Layout)
        $plan.Forwarders.Count | Should -Be 2
        ($plan.Forwarders | ForEach-Object BaseName) | Should -Contain "avcodec-62"
    }

    It "weist je Forwarder die erwarteten Ausgabepfade zu" {
        $plan = Get-Plan (New-Layout -Libs @("avcodec-62"))
        $fwd = $plan.Forwarders[0]
        $fwd.ForwarderDll   | Should -Match "avcodec-62\.dll$"
        $fwd.RealArm64Dll   | Should -Match "avcodec-62\.arm64\.dll$"
        $fwd.RealArm64ecDll | Should -Match "avcodec-62\.arm64ec\.dll$"
        $fwd.ForwardToArm64   | Should -Be "avcodec-62.arm64"
        $fwd.ForwardToArm64ec | Should -Be "avcodec-62.arm64ec"
    }

    It "baut den /machine:arm64x-Linkaufruf in der MS-dokumentierten Form" {
        $plan = Get-Plan (New-Layout -Libs @("avutil-60"))
        $linkArgs = Get-ForwarderLinkArgs -Fwd $plan.Forwarders[0]
        $linkArgs | Should -Contain "/dll"
        $linkArgs | Should -Contain "/noentry"
        $linkArgs | Should -Contain "/machine:arm64x"
        ($linkArgs -join " ") | Should -Match "/defArm64Native:\S+avutil-60\.arm64\.fwd\.def"
        ($linkArgs -join " ") | Should -Match "/def:\S+avutil-60\.arm64ec\.fwd\.def"
        ($linkArgs -join " ") | Should -Match "/out:\S+avutil-60\.dll"
    }

    It "bricht ab, wenn die ARM64EC-Ansicht eine DLL nicht hat" {
        $layout = New-Layout -Libs @("avcodec-62")
        Remove-Item (Join-Path $layout.Arm64ecDir "avcodec-62.dll")
        { Get-Plan $layout } | Should -Throw -ExpectedMessage "*ARM64EC-Ansicht fehlt*"
    }
}

Describe "merge-arm64x.ps1 DryRun" {
    It "gibt einen Plan mit allen Forwardern zurueck, ohne etwas zu schreiben" {
        $layout = New-Layout
        $out = & $script:Merge -Arm64Dir $layout.Arm64Dir -Arm64ecDir $layout.Arm64ecDir `
            -Arm64LibDir $layout.Arm64LibDir -Arm64ecLibDir $layout.Arm64ecLibDir `
            -OutputDir $layout.OutputDir -DryRun 6>$null
        $plan = @($out)[-1]
        @($plan.Forwarders).Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $layout.OutputDir -File).Count | Should -Be 0
    }
}