Function Find-TFSChange
    {
        Param(
		[Parameter(Mandatory=$true) ]$TFSServer, 
		[Parameter(Mandatory=$true) ]$Collection, 
		[Parameter(Mandatory=$true) ]$TFSTFSSourcePath, 
		[Parameter(Mandatory=$true) ]$Branch, 
		[Parameter(Mandatory=$true) ]$CurrentChangesetID,
		[Parameter(Mandatory=$true) ]$RunBookFolder
		)
        # Build the TFS Location (server and collection)
        
        $TFSServerCollection = $TFSServer + "\" + $Collection
        Write-Verbose -Message "Updating TFS Workspace $TFSServerCollection"

        $TFSRoot   = [System.String]::Empty
		$ReturnObj = @{ 
						'NumberOfItemsUpdated' = 0;
						'RunbookFiles' = @();
                        'UpdatedFiles' = @() 
					}
		
        Try
        {
            # Load the necessary assemblies for interacting with TFS
            $VClient  = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.TeamFoundation.VersionControl.Client")
            $TFClient = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.TeamFoundation.Client")
    
            # Connect to TFS
            $regProjCollection     = [Microsoft.TeamFoundation.Client.RegisteredTfsConnections]::GetProjectCollection($TFSServerCollection)
            $tfsTeamProjCollection = [Microsoft.TeamFoundation.Client.TfsTeamProjectCollectionFactory]::GetTeamProjectCollection($regProjCollection)
            $vcs                   = $tfsTeamProjCollection.GetService([Type]"Microsoft.TeamFoundation.VersionControl.Client.VersionControlServer")

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
                    Write-Debug -Message "Matching with environment Branchfolder config variable: $($Branch)"
                    
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
							
                            # Build list of all ps1 files in TFS folder, use for building workflow dependencies later
                            If(($FileExtension -eq "ps1") -and ($ServerPath -like $RunBookFolder)) {
                                # Create file list of all ps1 files in TFS folder Runbook
                                $ReturnObj.RunbookFiles += $ServerPath
                            }
                            
                            If($item.ChangesetID -gt $CurrentChangesetID)
                            {
                                Write-Debug -Message  "Found item with higher changeset ID, old: $ChangesetID new: $CurrentChangesetID"

								$ReturnObj.NumberOfItemsUpdated += 1
								$ReturnObj.UpdatedFiles += @{ 	
																'FullPath' = $ServerPath;
																'FileName' = $ServerPath.Split('\')[-1]
																'FileExtension' = $FileExtension;
																'ChangesetID' = $ChangesetID
															}
                            }
                        }
                    }
                }
            }
        }
        Catch { 
                Write-Exception -Stream Error -Exception $_
             }
        Write-Verbose -Message "Number of TFS items found to update: $($ReturnObj.NumberOfItemsUpdated)"
        Return (ConvertTo-Json -InputObject $ReturnObj)
}