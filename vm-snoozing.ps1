
    $connectionName = "AzureRunAsConnection";
 
    try
    {
        # Ensures you do not inherit an AzContext in your runbook
        Disable-AzContextAutosave -Scope Process

        # Connect to Azure with system-assigned managed identity
        $AzureContext = (Connect-AzAccount -Identity -AccountId "77e2ffb4-d505-492d-9883-**************").context

        # Get available Subscriptions
        $SubscriptionList = Get-AzContext -ListAvailable

    }
    catch {
 
        if (!$servicePrincipalConnection)
        {
            $ErrorMessage = "Connection $connectionName not found."
            throw $ErrorMessage
        } else{
            Write-Error -Message $_.Exception
            throw $_.Exception
        }
    }


foreach ($Subscription in $SubscriptionList){
        #Set Subscription Context
        Select-AzContext -Name $Subscription.Name

    #Get all VMs that should be part of the Schedule:
    $VMs = Get-AzResource -ResourceType "Microsoft.Compute/VirtualMachines" -TagName "Operational-Schedule" -TagValue "Yes"

    foreach ($VM in $VMs) {

    Write-Output "Processing VM $($VM.Name)..."

    ### Time Offset calculation

    #Get Current UTC Time (default time zone in all Azure regions)
    $UTCNow = [System.DateTime]::UtcNow

    #Get the Value of the "Operational-UTCOffset" Tag, that represents the offset from UTC
    $UTCOffset = $($VM.Tags)."Operational-UTCOffset"

    #Get current time in the Adjusted Time Zone
    if ($UTCOffset) {
        $TimeZoneAdjusted = $UTCNow.AddHours($UTCOffset)
        Write-Output "Current time of VM after adjusting the Time Zone is: $TimeZoneAdjusted"
    } else {
        $TimeZoneAdjusted = $UTCNow
    }


    ### Current Time associations

    $Day = $TimeZoneAdjusted.DayOfWeek

    If ($Day -like "S*") {
        $TodayIsWeekend = $true
        $TodayIsWeekday = $false

    } else {
        $TodayIsWeekend = $false
        $TodayIsWeekday = $true
    }

    
    ### Get Exclusions
    $Exclude = $false
    $Reason = ""
    $Exclusions = $($VM.Tags)."Operational-Exclusions"

    $Exclusions = $Exclusions.Split(',')
    
    foreach ($Exclusion in $Exclusions) {

        #Check excluded actions:
        If ($Exclusion.ToLower() -eq "stop") {$VMActionExcluded = "Stop"}
        If ($Exclusion.ToLower() -eq "start") {$VMActionExcluded = "Start"}
        
        #Check excluded days and compare with current day
        If ($Exclusion.ToLower() -like "*day") {
            if ($Exclusion -eq $Day) { $Exclude = $true; $Reason=$Day}
        }

        #Check excluded weekdays and copare with Today
        If ($Exclusion.ToLower() -eq "weekdays") {
                if ($TodayIsWeekday) {$Exclude = $true; $Reason="Weekday"}
        }

        #Check excluded weekends and compare with Today
        If ($Exclusion.ToLower() -eq "weekends") {
            if ($TodayIsWeekend) {$Exclude = $true; $Reason="Weekend"}
        }

        If ($Exclusion -eq (Get-Date -UFormat "%b %d")) {
            $Exclude = $true; $Reason = "Date Excluded"
        }

    }

    if (!$Exclude) {

        #Get values from Tags and compare to the current time

        if ($TodayIsWeekday) {

            $ScheduledTime = $($VM.Tags)."Operational-Weekdays"
        
        } elseif ($TodayIsWeekend) {

            $ScheduledTime = $($VM.Tags)."Operational-Weekends"

        }

        if ($ScheduledTime) {
            
            $ScheduledTime = $ScheduledTime.Split("-")
            $ScheduledStart = $ScheduledTime[0]
            $ScheduledStop = $ScheduledTime[1]
            
            $ScheduledStartTime = Get-Date -Hour $ScheduledStart -Minute 0 -Second 0
            $ScheduledStopTime = Get-Date -Hour $ScheduledStop -Minute 0 -Second 0

            If (($TimeZoneAdjusted -gt $ScheduledStartTime) -and ($TimeZoneAdjusted -lt $ScheduledStopTime)) {
                #Current time is within the interval
                Write-Output "VM should be running now"
                $VMAction = "Start"
            
            } else {
                #Current time is outside of the operational interval
                Write-Output "VM should be stopped now"
                $VMAction = "Stop"

            }

            If ($VMAction -notlike "$VMActionExcluded") { #Make sure that action was not excluded

                #Get VM PowerState status
                $VMObject = Get-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Status
                $VMState = ($VMObject.Statuses | Where-Object Code -like "*PowerState*").DisplayStatus
                
                if (($VMAction -eq "Start") -and ($VMState -notlike "*running")) {

                    Write-Output "Starting $($VM.Name)..."
                    Start-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name


                } elseif (($VMAction -eq "Stop") -and ($VMState -notlike "*deallocated")) {
                    
                    Write-Output "Stopping $($VM.Name)..."
                    Stop-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Force

                } else {

                    Write-Output "VM $($VM.Name) status is: $VMState . No action will be performed ..."

                }

                
            } else {
                Write-Output "VM $($VM.Name) is Excluded from changes during this run because Operational-Exclusions Tag contains action $VMAction."

            }


        } else {

            Write-Output "Error: Scheduled Running Time for VM was not detected. No action will be performed..."
        }
        

    } else {

        Write-Output "VM $($VM.Name) is Excluded from changes during this run because Operational-Exclusions Tag contains exclusion $Reason."
    }

}

}

Write-Output "Runbook completed."
