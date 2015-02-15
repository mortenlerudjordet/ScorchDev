﻿Function Find-TFSChange
    {
        Param(
		[Parameter(Mandatory=$true)]
        [string]
        $TFSServer, 
		[Parameter(Mandatory=$true)]
        [string]
        $Collection, 
		[Parameter(Mandatory=$true)]
        [string] 
        $TFSSourcePath, 
		[Parameter(Mandatory=$true)]
        [string] 
        $Branch, 
		[Parameter(Mandatory=$true)]
        [string] 
        $LastChangesetID,
		[Parameter(Mandatory=$true)]
        [string] 
        $RunBookFolder
		)
        # Build the TFS Location (server and collection)
        
        $TFSServerCollection = $TFSServer + "\" + $Collection
        Write-Verbose -Message "Updating TFS Workspace $TFSServerCollection"

        $TFSRoot   = [System.String]::Empty
		$ReturnObj = @{
						'NumberOfItemsUpdated' = 0;
						'LatestChangesetId' = 0;
                        'RunbookFiles' = @();
                        'UpdatedFiles' = @()
					}
		
        Try
        {
            # Load the necessary assemblies for interacting with TFS, VS Team Explorer or similar must be installed on SMA server for this to work
            $VClient  = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.TeamFoundation.VersionControl.Client")
            $TFClient = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.TeamFoundation.Client")
    
            # Connect to TFS
            $regProjCollection     = [Microsoft.TeamFoundation.Client.RegisteredTfsConnections]::GetProjectCollection($TFSServerCollection)
            $tfsTeamProjCollection = [Microsoft.TeamFoundation.Client.TfsTeamProjectCollectionFactory]::GetTeamProjectCollection($regProjCollection)
            $vcs                   = $tfsTeamProjCollection.GetService([Type]"Microsoft.TeamFoundation.VersionControl.Client.VersionControlServer")

            # Get the latest changeset ID from TFS
            $ReturnObj.LatestChangesetId = [int]($vcs.GetLatestChangesetId())

            # Setting up your workspace and source path you are managing
            $vcsWorkspace = $vcs.GetWorkspace($TFSSourcePath)

            # Update the local workspace
            $changes = $vcsWorkspace.Get()

            # If changes are found update runbooks in SMA
            If($changes.NumUpdated -gt 0)
            {
                Write-Verbose -Message "Changes Found, Processing"
                Write-Verbose -Message "Number of changes to process: $($changes.NumUpdated)"
                $allItems = $vcs.GetItems($TFSSourcePath,2)
                $TFSRoot  = ($allItems.QueryPath).ToLower()
                Write-Debug -Message "TFS Item Count: $($allItems.Items.Count)"
				Write-Debug -Message "TFS Root Path: $($TFSRoot)"
                foreach($item in $allItems.Items)
                {
					$BranchFolder = ($item.ServerItem).ToLower()
					$BranchFolder = ($BranchFolder.Split('/'))[-2]
                    Write-Debug -Message "Processing item: $($item.ServerItem)"
					Write-Debug -Message "Processing Branchfolder: $($BranchFolder)"
                    Write-Debug -Message "Filtering non branch folders not containing name: $($Branch)"
                    
                    If($BranchFolder -eq ($Branch.ToLower()))
                    {
                        Write-Debug -Message  "Match found for branch folder: $($BranchFolder)"
                        If($item.ItemType -eq "File")
                        {
                            # Find newest changeset from .ps1 and .xml
                            Write-Debug -Message  "Changeset ID: $($item.ChangesetID)"
                            $ServerItem  = $item.ServerItem
                            Write-Debug -Message "Processing item: $($ServerItem)"
                            $ServerPath = ((($ServerItem.ToLower()).Replace($TFSRoot.ToLower(), $TFSSourcePath.ToLower())).Replace('/','\'))
							Write-Debug -Message "Processing path: $($ServerPath)"
                            # Get file extension of item
                            $FileExtension = $ServerItem.Split('.')
                            $FileExtension = ($FileExtension[-1]).ToLower()
							
                            # Build list of all ps1 files in TFS folder filtered for files only in Runbook folder, use for building workflow dependencies later
                            If(($FileExtension -eq "ps1") -and ($ServerPath -like $RunBookFolder)) {
                                # Create file list of all ps1 files in TFS folder Runbook
                                $ReturnObj.RunbookFiles += $ServerPath
                            }
                            
                            If($item.ChangesetID -gt $LastChangesetID)
                            {
                                Write-Debug -Message  "Found item with higher changeset ID, old: $LastChangesetID new: $ChangesetID"
								$ReturnObj.NumberOfItemsUpdated += 1
								$ReturnObj.UpdatedFiles += @{ 	
																'FullPath' = $ServerPath;
																'FileName' = $ServerPath.Split('\')[-1];
																'FileExtension' = $FileExtension;
																'ChangesetID' = $ChangesetID
															}
                            }
                        }
                    }
                }
            }
            Else {
                Write-Debug -Message "No updates detected"
            }
        }
        Catch {
                Write-Exception -Stream Error -Exception $_
        }
        Write-Verbose -Message "Number of files in TFS altered: $($ReturnObj.NumberOfItemsUpdated)"
        Return (ConvertTo-Json -InputObject $ReturnObj)
}