# lib/Menu.ps1 - the guided interface.
#
# Counterpart of lib/menu.sh. The menu is a thin layer over the same commands
# the CLI exposes, so anything done here can also be scripted.

function Show-MenuInstalled {
    Write-Banner 'Sentinel Ops Installer'
    Write-Host ''
    Write-Host "Installation detected.  ($($script:INSTALL_DIR))"
    Write-Host ''
    Write-Host '  1. Update Sentinel Ops'
    Write-Host '  2. Update Supabase'
    Write-Host '  3. Update Everything'
    Write-Host '  4. System Status'
    Write-Host '  5. Credentials'
    Write-Host '  6. Backup database'
    Write-Host '  7. Rollback application'
    Write-Host '  8. Exit'
    Write-Host ''
    Write-Host 'Select: ' -NoNewline
}

function Show-MenuFresh {
    Write-Banner 'Sentinel Ops Installer'
    Write-Host ''
    Write-Host 'No existing installation detected.'
    Write-Host ''
    Write-Host '  1. Install Sentinel Ops'
    Write-Host '  2. Exit'
    Write-Host ''
    Write-Host 'Select: ' -NoNewline
}

function Invoke-CmdMenu {
    # A menu needs a terminal. Without one, say what to run instead of looping
    # forever on end-of-input.
    if (-not (Test-Interactive)) {
        Write-LogError 'The interactive menu needs a terminal.'
        Write-Host 'Use a subcommand instead, for example:'
        Write-Host '  sentinel-ops install -Yes'
        Write-Host '  sentinel-ops status'
        return 2
    }

    while ($true) {
        if (Test-InstallationExists) {
            Show-MenuInstalled
            $choice = Read-Host
            switch ($choice) {
                '1' { try { [void](Invoke-CmdUpdateApp) }      catch { Write-LogError $_.Exception.Message } }
                '2' { try { [void](Invoke-CmdUpdateSupabase) } catch { Write-LogError $_.Exception.Message } }
                '3' { try { [void](Invoke-CmdUpdateAll) }      catch { Write-LogError $_.Exception.Message } }
                '4' { try { [void](Invoke-CmdStatus) }         catch { Write-LogError $_.Exception.Message } }
                '5' { try { [void](Invoke-CmdCredentials) }    catch { Write-LogError $_.Exception.Message } }
                '6' { try { [void](Invoke-CmdBackup -Action 'create') } catch { Write-LogError $_.Exception.Message } }
                '7' { try { [void](Invoke-CmdRollback) }       catch { Write-LogError $_.Exception.Message } }
                { $_ -in @('8', 'q', 'quit', 'exit') } { return 0 }
                default { Write-LogWarn "Invalid selection: $choice" }
            }
        } else {
            Show-MenuFresh
            $choice = Read-Host
            switch ($choice) {
                '1' { try { [void](Invoke-CmdInstall) } catch { Write-LogError $_.Exception.Message } }
                { $_ -in @('2', 'q', 'quit', 'exit') } { return 0 }
                default { Write-LogWarn "Invalid selection: $choice" }
            }
        }
        Write-Host ''
        Write-Host 'Press Enter to return to the menu...' -NoNewline
        [void](Read-Host)
        Write-Host ''
    }
}
