GroupSwitchDB = GroupSwitchDB or {}
local GS = { version="1.4.6", profileNames={"NORMAL","BOSS 1","BOSS 2","BOSS 3"}, selected=1 }
local function Msg(t) DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99GroupSwitch|r : "..t) end
local function IsRaidLeaderOrOfficer()
 local playerName=UnitName("player")
 if not playerName then return false end

 for i=1,GetNumRaidMembers() do
  local name,rank=GetRaidRosterInfo(i)
  if name==playerName then
   -- Vanilla raid rank: 2 = leader, 1 = assistant, 0 = member
   if rank and rank>0 then return true end
   return false
  end
 end
 return false
end

local function EnsureDB() if type(GroupSwitchDB)~="table" then GroupSwitchDB={} end if type(GroupSwitchDB.profiles)~="table" then GroupSwitchDB.profiles={} end if type(GroupSwitchDB.knownPlayers)~="table" then GroupSwitchDB.knownPlayers={} end if type(GroupSwitchDB.profileMarkers)~="table" then GroupSwitchDB.profileMarkers={} end end
local function CanMove()
 if GetNumRaidMembers()==0 then return false end
 local me=UnitName("player")
 for i=1,GetNumRaidMembers() do local n,r=GetRaidRosterInfo(i); if n==me and r and r>0 then return true end end
 return false
end
local function PName() return GS.profileNames[GS.selected] end
local function DesiredGroup(profile,name)
 if profile and profile.players then return profile.players[name] end
 return nil
end
local function RaidMap()
 local m,c={},{}; for g=1,8 do c[g]=0 end
 for i=1,GetNumRaidMembers() do local n,r,g=GetRaidRosterInfo(i); if n then m[n]={index=i,group=g}; c[g]=(c[g] or 0)+1 end end
 return m,c
end
local function ProfileDisplayName(slot)
 EnsureDB()
 if not GroupSwitchDB.profileLabels then GroupSwitchDB.profileLabels={} end
 local label=GroupSwitchDB.profileLabels[slot]
 if label and label~="" then return label end
 return GS.profileNames[slot]
end

function GS:RenameSelected()
 GroupSwitchRenameFrame.slot=self.selected
 GroupSwitchRenameEditBox:SetText(ProfileDisplayName(self.selected))
 GroupSwitchRenameEditBox:HighlightText()
 GroupSwitchRenameFrame:Show()
 GroupSwitchRenameEditBox:SetFocus()
end

function GS:ConfirmRename()
 local slot=GroupSwitchRenameFrame.slot or self.selected
 local txt=GroupSwitchRenameEditBox:GetText() or ""
 txt=string.gsub(txt,"^%s+","")
 txt=string.gsub(txt,"%s+$","")
 if txt=="" then txt=self.profileNames[slot] end
 if not GroupSwitchDB.profileLabels then GroupSwitchDB.profileLabels={} end
 GroupSwitchDB.profileLabels[slot]=txt
 GroupSwitchRenameFrame:Hide()
 self:Refresh()
 Msg("profil renommé : |cffffff00"..txt.."|r.")
end

function GS:Save()
 if GetNumRaidMembers()==0 then Msg("vous n'êtes pas dans un raid."); return end
 EnsureDB(); local p={players={},saved=date("%Y-%m-%d %H:%M:%S")}
 for i=1,GetNumRaidMembers() do local n,r,g=GetRaidRosterInfo(i); if n and g then p.players[n]=g; GroupSwitchDB.knownPlayers[n]=true end end
 GroupSwitchDB.profiles[PName()]=p; Msg("|cffffff00"..ProfileDisplayName(self.selected).."|r enregistré ("..GetNumRaidMembers().." joueurs)."); self:Refresh()
end
function GS:ApplyProfileMarkers(profileSlot)
 EnsureDB()
 if not SetRaidTarget then return end
 local key=self.profileNames[profileSlot or self.selected]
 local markers=GroupSwitchDB.profileMarkers and GroupSwitchDB.profileMarkers[key]
 if type(markers)~="table" then return end

 local roster=RaidMap()
 local applied=0
 for name,marker in pairs(markers) do
  if marker and marker>=1 and marker<=8 then
   local found=nil
   local lname=string.lower(name)
   for raidName,info in pairs(roster) do
    if string.lower(raidName)==lname then found=info break end
   end
   if found and found.index then
    SetRaidTarget("raid"..found.index,marker)
    applied=applied+1
   end
  end
 end
 if applied>0 then Msg(applied.." symbole(s) de raid appliqué(s).") end
end

function GS:FinishApply()
 local profile=self.applyProfile
 local profileName=self.applyProfileName or "?"
 local roster=RaidMap()
 local present,correct=0,0
 local missing,unresolved={},{}
 for name,desired in pairs(profile.players) do
  local info=roster[name]
  if info then
   present=present+1
   if info.group==desired then
    correct=correct+1
   else
    table.insert(unresolved,name.." (G"..info.group.."->G"..desired..")")
   end
  else
   table.insert(missing,name)
  end
 end
 local appliedSlot=self.applyProfileSlot or self.selected
 self.applying=nil; self.waitingRoster=nil; self.rosterConfirmed=nil; self.applyDelay=nil; self.applyTimeout=nil; self.applyProfile=nil; self.applyProfileName=nil; self.applyProfileSlot=nil; self.applySteps=0
 Msg("|cffffff00"..profileName.."|r appliqué : "..correct.."/"..present.." joueurs placés.")
 if table.getn(missing)>0 then Msg("Absents : "..table.concat(missing,", ")) end
 if table.getn(unresolved)>0 then Msg("|cffff6666À placer manuellement :|r "..table.concat(unresolved,", ")) end
 self:ApplyProfileMarkers(appliedSlot)
 self:Refresh()
end

function GS:ContinueApply()
 if not self.applying or not self.applyProfile then return end

 local profile=self.applyProfile
 local roster,counts=RaidMap()
 local wrong=0
 for name,desired in pairs(profile.players) do
  local info=roster[name]
  if info and info.group~=desired then wrong=wrong+1 end
 end
 if wrong==0 then self:FinishApply(); return end

 self.applySteps=(self.applySteps or 0)+1
 if self.applySteps>160 then
  Msg("|cffff6666Application interrompue : trop de déplacements.|r")
  self:FinishApply()
  return
 end

 -- Moteur déterministe :
 -- Pour chaque joueur mal placé, on regarde SON groupe cible.
 -- S'il reste une place : déplacement simple.
 -- S'il est plein : on échange avec un occupant qui n'appartient pas
 -- à ce groupe dans le profil. Cela évite de dépendre de l'ordre de pairs().
 local moveName=nil
 local moveInfo=nil
 local moveWanted=nil

 for name,desired in pairs(profile.players) do
  local info=roster[name]
  if info and info.group~=desired then
   moveName=name
   moveInfo=info
   moveWanted=desired
   break
  end
 end

 if not moveName then self:FinishApply(); return end

 if (counts[moveWanted] or 0)<5 then
  self.waitingRoster=true
  self.rosterConfirmed=false
  self.applyTimeout=2.50
  SetRaidSubgroup(moveInfo.index,moveWanted)
  return
 end

 local blockerName=nil
 local blockerInfo=nil
 for other,oinfo in pairs(roster) do
  if oinfo.group==moveWanted and other~=moveName then
   local expected=profile.players[other]
   if expected~=moveWanted then
    blockerName=other
    blockerInfo=oinfo
    break
   end
  end
 end

 if blockerInfo then
  self.waitingRoster=true
  self.rosterConfirmed=false
  self.applyTimeout=2.50
  SwapRaidSubgroup(moveInfo.index,blockerInfo.index)
  return
 end

 -- Si on arrive ici, le groupe cible est rempli uniquement de joueurs
 -- que le profil demande déjà dans ce groupe. Le profil courant est donc
 -- incohérent pour les joueurs présents (plus de 5 demandes pour ce groupe).
 Msg("|cffff6666Impossible de placer "..moveName.." en G"..moveWanted..
     " : le groupe contient déjà 5 joueurs prévus par ce profil.|r")
 self:FinishApply()
end

function GS:Apply()
 if GetNumRaidMembers()==0 then Msg("vous n'êtes pas dans un raid."); return end
 if not IsRaidLeaderOrOfficer() then Msg("vous devez être chef de raid ou assistant."); return end
 EnsureDB()
 local profile=GroupSwitchDB.profiles[PName()]
 if not profile or not profile.players then Msg("aucune configuration enregistrée pour |cffffff00"..PName().."|r."); return end
 if self.applying then Msg("une configuration est déjà en cours d'application."); return end
 self.applying=true
 self.waitingRoster=false
 self.applyProfile=profile
 self.applyProfileName=ProfileDisplayName(self.selected)
 self.applyProfileSlot=self.selected
 self.applySteps=0
 self.applyDelay=nil
 self.applyTimeout=nil
 self.rosterConfirmed=nil
 Msg("application de |cffffff00"..PName().."|r...")
 self:ContinueApply()
end


local function TrimName(txt)
 txt=txt or ""
 txt=string.gsub(txt,"^%s+","")
 txt=string.gsub(txt,"%s+$","")
 return txt
end

function GS:AddKnownPlayerManual()
 EnsureDB()
 if not self.newKnownPlayerEdit then return end
 local name=TrimName(self.newKnownPlayerEdit:GetText() or "")
 if name=="" then
  Msg("|cffff6666Entrez un pseudo.|r")
  return
 end

 local lname=string.lower(name)
 for known,enabled in pairs(GroupSwitchDB.knownPlayers) do
  if enabled and string.lower(known)==lname then
   Msg("|cffffff00"..known.."|r est déjà dans les joueurs connus.")
   self.newKnownPlayerEdit:SetText("")
   self.newKnownPlayerEdit:ClearFocus()
   return
  end
 end

 GroupSwitchDB.knownPlayers[name]=true
 self.newKnownPlayerEdit:SetText("")
 self.newKnownPlayerEdit:ClearFocus()
 self.knownOffset=0
 self:RefreshKnownPlayers()
 Msg("|cff66ff66"..name.."|r ajouté aux joueurs connus.")
end

function GS:GetKnownPlayersSorted()
 EnsureDB()
 local names={}
 for name,enabled in pairs(GroupSwitchDB.knownPlayers) do
  if enabled then table.insert(names,name) end
 end
 table.sort(names,function(a,b) return string.lower(a)<string.lower(b) end)
 return names
end

function GS:IsEditorPlayerPlaced(name)
 local lname=string.lower(name or "")
 for g=1,8 do
  local txt=self.editorBoxes[g]:GetText() or ""
  for line in string.gfind(txt,"[^\r\n]+") do
   if string.lower(TrimName(line))==lname then return true,g end
  end
 end
 return false,nil
end

function GS:RefreshKnownPlayers()
 if not self.knownPlayerButtons then return end
 local names=self:GetKnownPlayersSorted()
 local pageSize=20
 local total=table.getn(names)
 local maxOffset=math.max(0,total-pageSize)
 self.knownOffset=self.knownOffset or 0
 if self.knownOffset>maxOffset then self.knownOffset=maxOffset end
 if self.knownOffset<0 then self.knownOffset=0 end
 for i=1,table.getn(self.knownPlayerButtons) do
  local b=self.knownPlayerButtons[i]
  local name=names[self.knownOffset+i]
  if name then
   b.playerName=name
   local placed,grp=self:IsEditorPlayerPlaced(name)
   if placed then b:SetText(name.." (G"..grp..")") else b:SetText(name) end
   b:Show()
  else b.playerName=nil; b:Hide() end
 end
 if self.knownRangeText then
  if total==0 then self.knownRangeText:SetText("0 joueur")
  else self.knownRangeText:SetText((self.knownOffset+1).."-"..math.min(self.knownOffset+pageSize,total).." / "..total) end
 end
 if self.knownUpButton then
  if self.knownOffset>0 then self.knownUpButton:Enable() else self.knownUpButton:Disable() end
 end
 if self.knownDownButton then
  if self.knownOffset<maxOffset then self.knownDownButton:Enable() else self.knownDownButton:Disable() end
 end
end

function GS:ScrollKnownPlayers(delta)
 self.knownOffset=(self.knownOffset or 0)+delta
 self:RefreshKnownPlayers()
end

function GS:AddKnownPlayerToGroup(name,group)
 if not name or name=="" then return end
 local placed,grp=self:IsEditorPlayerPlaced(name)
 if placed then Msg(name.." est déjà en G"..grp.."."); return end
 local eb=self.editorBoxes[group]
 local txt=eb:GetText() or ""
 local count=0
 for line in string.gfind(txt,"[^\r\n]+") do if TrimName(line)~="" then count=count+1 end end
 if count>=5 then Msg("|cffff6666Le groupe "..group.." contient déjà 5 joueurs.|r"); return end
 if txt~="" and string.sub(txt,-1)~="\n" then txt=txt.."\n" end
 eb:SetText(txt..name)
 self:RefreshKnownPlayers()
 self:RefreshEditorDragPlayers()
end

function GS:RemovePlayerFromEditor(name)
 if not name or name=="" then return end
 local lname=string.lower(name)
 local removed=false
 for g=1,8 do
  local txt=self.editorBoxes[g]:GetText() or ""
  local keep={}
  for line in string.gfind(txt,"[^\r\n]+") do
   local current=TrimName(line)
   if current~="" then
    if string.lower(current)==lname then
     removed=true
    else
     table.insert(keep,current)
    end
   end
  end
  self.editorBoxes[g]:SetText(table.concat(keep,"\n"))
 end
 if removed then
  Msg("|cffffff00"..name.."|r retiré du profil.")
  self:RefreshKnownPlayers()
  self:RefreshEditorDragPlayers()
 end
end

function GS:DeleteKnownPlayer(name)
 if not name or name=="" then return end
 EnsureDB()
 GroupSwitchDB.knownPlayers[name]=nil
 Msg("|cffffff00"..name.."|r supprimé des joueurs connus.")
 self:RefreshKnownPlayers()
end

function GS:AskDeleteKnownPlayer(name)
 if not name then return end
 self.pendingDeleteKnownPlayer=name
 self.deleteKnownText:SetText("Supprimer |cffffff00"..name.."|r de la liste des joueurs connus ?")
 self.deleteKnownFrame:Show()
end

function GS:ChooseKnownPlayer(name)
 if not name then return end
 local placed,grp=self:IsEditorPlayerPlaced(name)
 if placed then
  self.pendingRemovePlayer=name
  self.removeConfirmText:SetText("Retirer |cffffff00"..name.."|r du groupe "..grp.." ?")
  self.removeConfirmFrame:Show()
  return
 end
 self.pendingKnownPlayer=name
 self.groupChoiceLabel:SetText("Placer "..name.." dans :")
 self.groupChoiceFrame:Show()
end

function GS:OpenEditor()
 EnsureDB()
 if not self.editor then self:CreateEditor() end
 local key=PName()
 local profile=GroupSwitchDB.profiles[key]
 for g=1,8 do
  local names={}
  if profile and profile.players then
   for name,grp in pairs(profile.players) do
    if grp==g then table.insert(names,name) end
   end
  end
  table.sort(names)
  self.editorBoxes[g]:SetText(table.concat(names,"\n"))
 end
 self.editorTitle:SetText("Édition : |cffffff00"..ProfileDisplayName(self.selected).."|r")
 self.editor.slot=self.selected
 self.knownOffset=0
 self.editor:Show()
 self:RefreshEditorSlots()
 self:RefreshKnownPlayers()
end

function GS:MoveEditorPlayer(name,targetGroup)
 if not name or not targetGroup then return end
 local sourceGroup=nil
 local lname=string.lower(name)
 local targetCount=0

 for g=1,8 do
  local txt=self.editorBoxes[g]:GetText() or ""
  local keep={}
  for line in string.gfind(txt,"[^\r\n]+") do
   local current=TrimName(line)
   if current~="" then
    if string.lower(current)==lname then
     sourceGroup=g
    else
     table.insert(keep,current)
     if g==targetGroup then targetCount=targetCount+1 end
    end
   end
  end
  if sourceGroup==g then self.editorBoxes[g]:SetText(table.concat(keep,"\n")) end
 end

 if not sourceGroup then return end
 if sourceGroup==targetGroup then
  local txt=self.editorBoxes[sourceGroup]:GetText() or ""
  if txt~="" then txt=txt.."\n" end
  self.editorBoxes[sourceGroup]:SetText(txt..name)
  self:RefreshEditorDragPlayers()
  return
 end

 if targetCount>=5 then
  local txt=self.editorBoxes[sourceGroup]:GetText() or ""
  if txt~="" then txt=txt.."\n" end
  self.editorBoxes[sourceGroup]:SetText(txt..name)
  Msg("|cffff6666G"..targetGroup.." contient déjà 5 joueurs.|r")
  self:RefreshEditorDragPlayers()
  return
 end

 local target=self.editorBoxes[targetGroup]:GetText() or ""
 if target~="" and string.sub(target,-1)~="\n" then target=target.."\n" end
 self.editorBoxes[targetGroup]:SetText(target..name)
 self:RefreshEditorDragPlayers()
 self:RefreshKnownPlayers()
end

function GS:GetEditorGroupNames(group)
 local names={}
 local txt=self.editorBoxes[group]:GetText() or ""
 for line in string.gfind(txt,"[^\r\n]+") do
  local name=TrimName(line)
  if name~="" then table.insert(names,name) end
 end
 return names
end

function GS:SetEditorGroupNames(group,names)
 self.editorBoxes[group]:SetText(table.concat(names,"\n"))
end

local GS_MARKERS = {
 {id=1,label="{star}",name="Étoile"},
 {id=2,label="{circle}",name="Cercle"},
 {id=3,label="{diamond}",name="Losange"},
 {id=4,label="{triangle}",name="Triangle"},
 {id=5,label="{moon}",name="Lune"},
 {id=6,label="{square}",name="Carré"},
 {id=7,label="{cross}",name="Croix"},
 {id=8,label="{skull}",name="Crâne"}
}

function GS:GetEditorProfileMarkerTable()
 EnsureDB()
 local slot=(self.editor and self.editor.slot) or self.selected
 local key=self.profileNames[slot]
 if type(GroupSwitchDB.profileMarkers[key])~="table" then GroupSwitchDB.profileMarkers[key]={} end
 return GroupSwitchDB.profileMarkers[key]
end

function GS:GetPlayerMarker(name)
 if not name then return nil end
 local markers=self:GetEditorProfileMarkerTable()
 return markers[string.lower(name)]
end

function GS:SetPlayerMarker(name,marker)
 if not name then return end
 local markers=self:GetEditorProfileMarkerTable()
 local key=string.lower(name)
 if marker then markers[key]=marker else markers[key]=nil end
 self:RefreshEditorSlots()
end

function GS:OpenMarkerMenu(button)
 if not button or not button.playerName or not self.markerMenu then return end
 self.markerPlayer=button.playerName
 self.markerMenuTitle:SetText("Symbole : |cffffff00"..button.playerName.."|r")
 self.markerMenu:ClearAllPoints()
 self.markerMenu:SetPoint("TOPLEFT",button,"BOTTOMLEFT",0,-2)
 self.markerMenu:Show()
end

function GS:RefreshEditorSlots()
 if not self.editorSlotButtons then return end
 for g=1,8 do
  local names=self:GetEditorGroupNames(g)
  for row=1,5 do
   local b=self.editorSlotButtons[g][row]
   local name=names[row]
   if name then
    b.playerName=name
    local marker=self:GetPlayerMarker(name)
    b:SetText(name)
    if b.markerTexture then
     if marker then
      local coords={
       [1]={0.00,0.25,0.00,0.25},
       [2]={0.25,0.50,0.00,0.25},
       [3]={0.50,0.75,0.00,0.25},
       [4]={0.75,1.00,0.00,0.25},
       [5]={0.00,0.25,0.25,0.50},
       [6]={0.25,0.50,0.25,0.50},
       [7]={0.50,0.75,0.25,0.50},
       [8]={0.75,1.00,0.25,0.50}
      }
      local c=coords[marker]
      b.markerTexture:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
      if c then b.markerTexture:SetTexCoord(c[1],c[2],c[3],c[4]) end
      b.markerTexture:Show()
     else
      b.markerTexture:Hide()
     end
    end
    b:EnableMouse(true)
    b:Show()
   else
    b.playerName=nil
    b:SetText("")
    if b.markerTexture then b.markerTexture:Hide() end
    b:EnableMouse(false)
    b:Hide()
   end
  end
 end
end

function GS:RefreshEditorDragPlayers()
 -- Compatibilité avec les fonctions historiques de l'éditeur.
 self:RefreshEditorSlots()
end

function GS:EditorSlotDragStart(button)
 if not button or not button.playerName then return end
 self.draggingPlayer=button.playerName
 self.dragSourceGroup=button.groupNumber
 self.dragSourceRow=button.rowNumber
 if self.dragGhost then
  self.dragGhostText:SetText(button.playerName)
  self.dragGhost:Show()
 end
 if self.editor then self.editor:SetScript("OnUpdate",function() GS:UpdateEditorDragGhost() end) end
end

function GS:UpdateEditorDragGhost()
 if not self.draggingPlayer or not self.dragGhost then return end
 local x,y=GetCursorPosition()
 local scale=UIParent:GetEffectiveScale() or 1
 x=x/scale; y=y/scale
 self.dragGhost:ClearAllPoints()
 self.dragGhost:SetPoint("BOTTOMLEFT",UIParent,"BOTTOMLEFT",x+12,y+8)
end

function GS:GetEditorDropTarget()
 local x,y=GetCursorPosition()
 local scale=UIParent:GetEffectiveScale() or 1
 x=x/scale; y=y/scale
 for g=1,8 do
  local f=self.editorGroupFrames[g]
  local l,r,t,b=f:GetLeft(),f:GetRight(),f:GetTop(),f:GetBottom()
  if l and r and t and b and x>=l and x<=r and y>=b and y<=t then
   local names=self:GetEditorGroupNames(g)
   local row=nil
   for i=1,5 do
    local sb=self.editorSlotButtons[g][i]
    if sb and sb:IsShown() then
     local sl,sr,st,sbott=sb:GetLeft(),sb:GetRight(),sb:GetTop(),sb:GetBottom()
     if sl and sr and st and sbott and x>=sl and x<=sr and y>=sbott and y<=st then
      row=i
      break
     end
    end
   end
   return g,row,names
  end
 end
 return nil,nil,nil
end

function GS:EditorSlotDragStop(button)
 if self.editor then self.editor:SetScript("OnUpdate",nil) end
 if self.dragGhost then self.dragGhost:Hide() end

 local name=self.draggingPlayer
 local sourceGroup=self.dragSourceGroup
 local sourceRow=self.dragSourceRow
 self.draggingPlayer=nil
 self.dragSourceGroup=nil
 self.dragSourceRow=nil

 if not name or not sourceGroup then return end
 local targetGroup,targetRow,targetNames=self:GetEditorDropTarget()
 if not targetGroup or targetGroup==sourceGroup then
  self:RefreshEditorSlots()
  return
 end

 local sourceNames=self:GetEditorGroupNames(sourceGroup)
 if sourceNames[sourceRow]~=name then
  sourceRow=nil
  for i=1,table.getn(sourceNames) do
   if sourceNames[i]==name then sourceRow=i break end
  end
 end
 if not sourceRow then self:RefreshEditorSlots(); return end

 if table.getn(targetNames)<5 then
  table.remove(sourceNames,sourceRow)
  table.insert(targetNames,name)
 else
  -- Groupe plein : le dépôt doit viser un joueur, puis les deux permutent.
  if not targetRow or not targetNames[targetRow] then
   Msg("|cffff6666G"..targetGroup.." est plein : déposez le joueur directement sur le pseudo à échanger.|r")
   self:RefreshEditorSlots()
   return
  end
  local other=targetNames[targetRow]
  targetNames[targetRow]=name
  sourceNames[sourceRow]=other
 end

 self:SetEditorGroupNames(sourceGroup,sourceNames)
 self:SetEditorGroupNames(targetGroup,targetNames)
 self:RefreshEditorSlots()
 self:RefreshKnownPlayers()
end

function GS:ChooseEditorPlayer(name)
 if not name or name=="" then return end
 self.pendingEditorPlayer=name
 if self.editorMoveLabel then
  self.editorMoveLabel:SetText("Déplacer |cffffff00"..name.."|r vers :")
 end
 if self.editorMoveFrame then self.editorMoveFrame:Show() end
end

function GS:MoveSelectedEditorPlayer(group)
 local name=self.pendingEditorPlayer
 self.pendingEditorPlayer=nil
 if self.editorMoveFrame then self.editorMoveFrame:Hide() end
 if name and group then self:MoveEditorPlayer(name,group) end
end

function GS:ClearEditorProfile()
 for g=1,8 do
  if self.editorBoxes[g] then self.editorBoxes[g]:SetText("") end
 end
 self:RefreshKnownPlayers()
 self:RefreshEditorDragPlayers()
 Msg("|cffffff00Édition vidée.|r Cliquez sur Enregistrer pour valider la composition vide.")
end

function GS:SaveEditor()
 EnsureDB()
 local slot=self.editor.slot or self.selected
 local key=self.profileNames[slot]
 local players={}
 local total=0
 local seen={}
 for g=1,8 do
  local txt=self.editorBoxes[g]:GetText() or ""
  local count=0
  for line in string.gfind(txt,"[^\r\n]+") do
   local name=TrimName(line)
   if name~="" then
    count=count+1
    if count>5 then
     Msg("|cffff6666G"..g.." contient plus de 5 joueurs.|r")
     return
    end
    local lower=string.lower(name)
    if seen[lower] then
     Msg("|cffff6666"..name.." est présent plusieurs fois.|r")
     return
    end
    seen[lower]=true
    players[name]=g
    GroupSwitchDB.knownPlayers[name]=true
    total=total+1
   end
  end
 end
 GroupSwitchDB.profiles[key]={players=players,saved=date("%Y-%m-%d %H:%M:%S")}
 self.editor:Hide()
 self.selected=slot
 self:Refresh()
 Msg("|cffffff00"..ProfileDisplayName(slot).."|r enregistré depuis l'éditeur ("..total.." joueurs).")
end

function GS:CreateEditor()
 if self.editor then return end
 local f=CreateFrame("Frame","GroupSwitchEditorFrame",UIParent)
 f:SetWidth(930); f:SetHeight(470)
 f:SetPoint("CENTER",UIParent,"CENTER",0,0)
 f:SetFrameStrata("FULLSCREEN_DIALOG")
 f:EnableMouse(true)
 f:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})

 local title=f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
 title:SetPoint("TOP",f,"TOP",0,-18)
 title:SetText("Éditeur GroupSwitch")
 self.editorTitle=title

 local close=CreateFrame("Button",nil,f,"UIPanelCloseButton")
 close:SetPoint("TOPRIGHT",f,"TOPRIGHT",-5,-5)

 local help=f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
 help:SetPoint("TOP",title,"BOTTOM",0,-7)
 help:SetText("Glissez un joueur pour le déplacer • clic droit sur un pseudo : symbole du profil")

 self.editorBoxes={}
 self.editorSlotButtons={}
 self.editorGroupFrames={}
 for g=1,8 do
  local col=math.mod(g-1,4)
  local row=math.floor((g-1)/4)
  local x=25+col*168
  local y=-78-row*145

  local gl=f:CreateFontString(nil,"OVERLAY","GameFontNormal")
  gl:SetPoint("TOPLEFT",f,"TOPLEFT",x,y)
  gl:SetText("Groupe "..g)

  local bg=CreateFrame("Frame",nil,f)
  bg:SetWidth(150); bg:SetHeight(105)
  bg:SetPoint("TOPLEFT",gl,"BOTTOMLEFT",0,-5)
  bg:SetBackdrop({bgFile="Interface\\Tooltips\\UI-Tooltip-Background",edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",tile=true,tileSize=16,edgeSize=12,insets={left=3,right=3,top=3,bottom=3}})
  bg:SetBackdropColor(0,0,0,0.85)
  self.editorGroupFrames[g]=bg

  -- Stockage interne uniquement. L'affichage et la souris ne dépendent plus de l'EditBox.
  local eb=CreateFrame("EditBox",nil,bg)
  eb:SetWidth(1); eb:SetHeight(1)
  eb:SetPoint("BOTTOMLEFT",bg,"BOTTOMLEFT",0,0)
  eb:SetMultiLine(true)
  eb:SetAutoFocus(false)
  eb:EnableMouse(false)
  eb:SetAlpha(0)
  self.editorBoxes[g]=eb

  self.editorSlotButtons[g]={}
  for r=1,5 do
   local sb=CreateFrame("Button",nil,bg)
   sb:SetWidth(136); sb:SetHeight(18)
   sb:SetPoint("TOPLEFT",bg,"TOPLEFT",7,-6-(r-1)*18)
   sb:EnableMouse(true)
   sb:RegisterForDrag("LeftButton")
   sb.groupNumber=g
   sb.rowNumber=r

   local hl=sb:CreateTexture(nil,"HIGHLIGHT")
   hl:SetAllPoints(sb)
   hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
   hl:SetBlendMode("ADD")

   local txt=sb:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
   txt:SetPoint("LEFT",sb,"LEFT",2,0)
   txt:SetPoint("RIGHT",sb,"RIGHT",-2,0)
   txt:SetJustifyH("LEFT")
   sb.text=txt
   sb.SetText=function(self,value) self.text:SetText(value or "") end

   local markerTexture=sb:CreateTexture(nil,"OVERLAY")
   markerTexture:SetWidth(14); markerTexture:SetHeight(14)
   markerTexture:SetPoint("RIGHT",sb,"RIGHT",-2,0)
   markerTexture:Hide()
   sb.markerTexture=markerTexture

   sb:SetScript("OnDragStart",function() GS:EditorSlotDragStart(this) end)
   sb:SetScript("OnDragStop",function() GS:EditorSlotDragStop(this) end)
   sb:RegisterForClicks("LeftButtonUp","RightButtonUp")
   sb:SetScript("OnClick",function()
    if arg1=="RightButton" then GS:OpenMarkerMenu(this) end
   end)
   sb:Hide()
   self.editorSlotButtons[g][r]=sb
  end
 end

 -- Fantôme visuel indépendant : il suit la souris sans déplacer/reparenter le bouton source.
 local ghost=CreateFrame("Frame",nil,UIParent)
 ghost:SetWidth(145); ghost:SetHeight(20)
 ghost:SetFrameStrata("TOOLTIP")
 ghost:SetBackdrop({bgFile="Interface\\Tooltips\\UI-Tooltip-Background",edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",tile=true,tileSize=8,edgeSize=8,insets={left=2,right=2,top=2,bottom=2}})
 ghost:SetBackdropColor(0,0,0,0.95)
 ghost:EnableMouse(false)
 local gt=ghost:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
 gt:SetPoint("LEFT",ghost,"LEFT",6,0)
 gt:SetPoint("RIGHT",ghost,"RIGHT",-4,0)
 gt:SetJustifyH("LEFT")
 ghost:Hide()
 self.dragGhost=ghost
 self.dragGhostText=gt

 -- Menu de symbole visuel du profil. Il ne pose aucun symbole en jeu.
 local mm=CreateFrame("Frame","GroupSwitchMarkerMenu",f)
 mm:SetWidth(175); mm:SetHeight(218)
 mm:SetFrameStrata("TOOLTIP")
 mm:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=16,edgeSize=16,insets={left=5,right=5,top=5,bottom=5}})
 local mmt=mm:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
 mmt:SetPoint("TOP",mm,"TOP",0,-10)
 self.markerMenuTitle=mmt
 for i=1,8 do
  local mb=CreateFrame("Button",nil,mm,"UIPanelButtonTemplate")
  mb:SetWidth(145); mb:SetHeight(19)
  mb:SetPoint("TOP",mm,"TOP",0,-30-(i-1)*20)
  mb.markerId=GS_MARKERS[i].id
  mb:SetText(GS_MARKERS[i].name)
  mb:SetScript("OnClick",function()
   GS:SetPlayerMarker(GS.markerPlayer,this.markerId)
   GroupSwitchMarkerMenu:Hide()
  end)
 end
 local none=CreateFrame("Button",nil,mm,"UIPanelButtonTemplate")
 none:SetWidth(145); none:SetHeight(19)
 none:SetPoint("BOTTOM",mm,"BOTTOM",0,8)
 none:SetText("Aucun symbole")
 none:SetScript("OnClick",function()
  GS:SetPlayerMarker(GS.markerPlayer,nil)
  GroupSwitchMarkerMenu:Hide()
 end)
 mm:Hide()
 self.markerMenu=mm

 local mf=CreateFrame("Frame","GroupSwitchEditorMoveFrame",f)
 mf:SetWidth(270); mf:SetHeight(110)
 mf:SetPoint("CENTER",f,"CENTER",0,0)
 mf:SetFrameStrata("TOOLTIP")
 mf:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=32,edgeSize=20,insets={left=6,right=6,top=6,bottom=6}})
 local ml=mf:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
 ml:SetPoint("TOP",mf,"TOP",0,-13)
 ml:SetText("Déplacer le joueur vers :")
 self.editorMoveLabel=ml
 for g=1,8 do
  local mb=CreateFrame("Button",nil,mf,"UIPanelButtonTemplate")
  mb:SetWidth(42); mb:SetHeight(20)
  local col=math.mod(g-1,4)
  local row=math.floor((g-1)/4)
  mb:SetPoint("TOPLEFT",mf,"TOPLEFT",25+col*52,-38-row*24)
  mb:SetText("G"..g)
  mb.groupNumber=g
  mb:SetScript("OnClick",function() GS:MoveSelectedEditorPlayer(this.groupNumber) end)
 end
 mf:Hide()
 self.editorMoveFrame=mf

 local clear=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
 clear:SetWidth(150); clear:SetHeight(28)
 clear:SetPoint("BOTTOMLEFT",f,"BOTTOMLEFT",25,25)
 clear:SetText("Vider l'édition")
 clear:SetScript("OnClick",function() GS:ClearEditorProfile() end)

 local save=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
 save:SetWidth(150); save:SetHeight(28)
 save:SetPoint("BOTTOMLEFT",f,"BOTTOMLEFT",185,25)
 save:SetText("Enregistrer")
 save:SetScript("OnClick",function() GS:SaveEditor() end)

 local cancel=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
 cancel:SetWidth(150); cancel:SetHeight(28)
 cancel:SetPoint("BOTTOMLEFT",f,"BOTTOMLEFT",365,25)
 cancel:SetText("Annuler")
 cancel:SetScript("OnClick",function() GroupSwitchEditorFrame:Hide() end)

 local sep=f:CreateTexture(nil,"ARTWORK")
 sep:SetTexture(0.45,0.45,0.45,0.7)
 sep:SetWidth(1); sep:SetHeight(300)
 sep:SetPoint("TOPLEFT",f,"TOPLEFT",700,-70)

 local addTitle=f:CreateFontString(nil,"OVERLAY","GameFontNormal")
 addTitle:SetPoint("TOPLEFT",f,"TOPLEFT",720,-72)
 addTitle:SetText("Ajouter un joueur")

 local addBox=CreateFrame("EditBox","GroupSwitchNewKnownPlayerEdit",f,"InputBoxTemplate")
 addBox:SetWidth(125); addBox:SetHeight(22)
 addBox:SetPoint("TOPLEFT",addTitle,"BOTTOMLEFT",5,-5)
 addBox:SetAutoFocus(false)
 addBox:SetMaxLetters(20)
 addBox:SetScript("OnEnterPressed",function() GS:AddKnownPlayerManual() end)
 addBox:SetScript("OnEscapePressed",function() this:ClearFocus() end)
 self.newKnownPlayerEdit=addBox

 local addButton=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
 addButton:SetWidth(55); addButton:SetHeight(22)
 addButton:SetPoint("LEFT",addBox,"RIGHT",5,0)
 addButton:SetText("Ajouter")
 addButton:SetScript("OnClick",function() GS:AddKnownPlayerManual() end)

 local rt=f:CreateFontString(nil,"OVERLAY","GameFontNormal")
 rt:SetPoint("TOPLEFT",f,"TOPLEFT",720,-125)
 rt:SetText("Joueurs connus")

 local rh=f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
 rh:SetWidth(185); rh:SetJustifyH("LEFT")
 rh:SetPoint("TOPLEFT",rt,"BOTTOMLEFT",0,-5)
 rh:SetText("Clic gauche : placer / retirer.\nClic droit : supprimer.")

 self.knownPlayerButtons={}
 for i=1,20 do
  local b=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
  b:SetWidth(185); b:SetHeight(18)
  b:SetPoint("TOPLEFT",f,"TOPLEFT",720,-163-(i-1)*13)
  b:SetText("")
  b:RegisterForClicks("LeftButtonUp","RightButtonUp")
  b:SetScript("OnClick",function()
   if not this.playerName then return end
   if arg1=="RightButton" then GS:AskDeleteKnownPlayer(this.playerName) else GS:ChooseKnownPlayer(this.playerName) end
  end)
  b:Hide()
  self.knownPlayerButtons[i]=b
 end

 local up=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
 up:SetWidth(55); up:SetHeight(22); up:SetPoint("TOPLEFT",f,"TOPLEFT",720,-428)
 up:SetText("Haut"); up:SetScript("OnClick",function() GS:ScrollKnownPlayers(-20) end)
 self.knownUpButton=up

 local range=f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
 range:SetWidth(70); range:SetPoint("LEFT",up,"RIGHT",3,0); range:SetJustifyH("CENTER")
 range:SetText("0 joueur"); self.knownRangeText=range

 local down=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
 down:SetWidth(55); down:SetHeight(22); down:SetPoint("LEFT",range,"RIGHT",3,0)
 down:SetText("Bas"); down:SetScript("OnClick",function() GS:ScrollKnownPlayers(20) end)
 self.knownDownButton=down

 local gc=CreateFrame("Frame","GroupSwitchGroupChoiceFrame",f)
 gc:SetWidth(210); gc:SetHeight(90)
 gc:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-12,20)
 gc:SetFrameStrata("TOOLTIP")
 gc:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=32,edgeSize=20,insets={left=6,right=6,top=6,bottom=6}})
 local gcl=gc:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
 gcl:SetPoint("TOP",gc,"TOP",0,-12); gcl:SetText("Placer dans :")
 self.groupChoiceLabel=gcl
 self.groupChoiceButtons={}
 for g=1,8 do
  local b=CreateFrame("Button",nil,gc,"UIPanelButtonTemplate")
  b:SetWidth(42); b:SetHeight(20)
  local col=math.mod(g-1,4); local row=math.floor((g-1)/4)
  b:SetPoint("TOPLEFT",gc,"TOPLEFT",15+col*47,-35-row*23)
  b:SetText("G"..g); b.groupNumber=g
  b:SetScript("OnClick",function()
   local name=GS.pendingKnownPlayer
   local group=this.groupNumber
   GroupSwitchGroupChoiceFrame:Hide()
   GS.pendingKnownPlayer=nil
   GS:AddKnownPlayerToGroup(name,group)
  end)
  self.groupChoiceButtons[g]=b
 end
 gc:Hide(); self.groupChoiceFrame=gc

 local rc=CreateFrame("Frame","GroupSwitchRemoveConfirmFrame",f)
 rc:SetWidth(280); rc:SetHeight(105)
 rc:SetPoint("CENTER",f,"CENTER",0,0)
 rc:SetFrameStrata("TOOLTIP")
 rc:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=32,edgeSize=20,insets={left=6,right=6,top=6,bottom=6}})
 local rct=rc:CreateFontString(nil,"OVERLAY","GameFontNormal")
 rct:SetWidth(240); rct:SetPoint("TOP",rc,"TOP",0,-20)
 rct:SetText("Retirer ce joueur du profil ?")
 self.removeConfirmText=rct

 local yes=CreateFrame("Button",nil,rc,"UIPanelButtonTemplate")
 yes:SetWidth(90); yes:SetHeight(22); yes:SetPoint("BOTTOMLEFT",rc,"BOTTOMLEFT",42,18)
 yes:SetText("Retirer")
 yes:SetScript("OnClick",function()
  local name=GS.pendingRemovePlayer
  GroupSwitchRemoveConfirmFrame:Hide()
  GS.pendingRemovePlayer=nil
  GS:RemovePlayerFromEditor(name)
 end)

 local no=CreateFrame("Button",nil,rc,"UIPanelButtonTemplate")
 no:SetWidth(90); no:SetHeight(22); no:SetPoint("BOTTOMRIGHT",rc,"BOTTOMRIGHT",-42,18)
 no:SetText("Annuler")
 no:SetScript("OnClick",function()
  GroupSwitchRemoveConfirmFrame:Hide()
  GS.pendingRemovePlayer=nil
 end)
 rc:Hide()
 self.removeConfirmFrame=rc

 local dc=CreateFrame("Frame","GroupSwitchDeleteKnownFrame",f)
 dc:SetWidth(320); dc:SetHeight(115)
 dc:SetPoint("CENTER",f,"CENTER",0,0)
 dc:SetFrameStrata("TOOLTIP")
 dc:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=32,edgeSize=20,insets={left=6,right=6,top=6,bottom=6}})
 local dct=dc:CreateFontString(nil,"OVERLAY","GameFontNormal")
 dct:SetWidth(275); dct:SetPoint("TOP",dc,"TOP",0,-20)
 dct:SetText("Supprimer ce joueur des joueurs connus ?")
 self.deleteKnownText=dct

 local yes2=CreateFrame("Button",nil,dc,"UIPanelButtonTemplate")
 yes2:SetWidth(100); yes2:SetHeight(22); yes2:SetPoint("BOTTOMLEFT",dc,"BOTTOMLEFT",48,18)
 yes2:SetText("Supprimer")
 yes2:SetScript("OnClick",function()
  local name=GS.pendingDeleteKnownPlayer
  GroupSwitchDeleteKnownFrame:Hide()
  GS.pendingDeleteKnownPlayer=nil
  GS:DeleteKnownPlayer(name)
 end)

 local no2=CreateFrame("Button",nil,dc,"UIPanelButtonTemplate")
 no2:SetWidth(100); no2:SetHeight(22); no2:SetPoint("BOTTOMRIGHT",dc,"BOTTOMRIGHT",-48,18)
 no2:SetText("Annuler")
 no2:SetScript("OnClick",function()
  GroupSwitchDeleteKnownFrame:Hide()
  GS.pendingDeleteKnownPlayer=nil
 end)
 dc:Hide()
 self.deleteKnownFrame=dc

 f:Hide()
 self.editor=f
end

function GS:Refresh()
 if not self.frame then return end; EnsureDB()
 for i=1,4 do local n=self.profileNames[i]; local p=GroupSwitchDB.profiles[n]; local b=self.buttons[i]; local count=0; if p and p.players then for k,v in pairs(p.players) do count=count+1 end end; b:SetText(ProfileDisplayName(i)..(count>0 and " ("..count..")" or " (vide)")); if i==self.selected then b:LockHighlight() else b:UnlockHighlight() end end
 self.profileLabel:SetText("Profil sélectionné : |cffffff00"..ProfileDisplayName(self.selected).."|r")
end
function GS:CreateUI()
 if self.frame then return end
 local f=CreateFrame("Frame","GroupSwitchFrame",UIParent); f:SetWidth(360); f:SetHeight(335); f:SetPoint("CENTER",UIParent,"CENTER",0,0); f:SetFrameStrata("DIALOG"); f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton"); f:SetScript("OnDragStart",function() this:StartMoving() end); f:SetScript("OnDragStop",function() this:StopMovingOrSizing() end)
 f:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
 local title=f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge"); title:SetPoint("TOP",f,"TOP",0,-18); title:SetText("GroupSwitch")
 local close=CreateFrame("Button",nil,f,"UIPanelCloseButton"); close:SetPoint("TOPRIGHT",f,"TOPRIGHT",-5,-5)
 local info=f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); info:SetPoint("TOP",title,"BOTTOM",0,-8); info:SetText("Sauvegarde et applique une composition de raid en un clic.")
 local lab=f:CreateFontString(nil,"OVERLAY","GameFontNormal"); lab:SetPoint("TOPLEFT",f,"TOPLEFT",24,-70); self.profileLabel=lab
 self.buttons={}
 for i=1,4 do local b=CreateFrame("Button",nil,f,"UIPanelButtonTemplate"); b:SetWidth(145); b:SetHeight(28); local col=math.mod(i-1,2); local row=math.floor((i-1)/2); b:SetPoint("TOPLEFT",f,"TOPLEFT",25+col*165,-105-row*38); b.gsProfileIndex=i; b:SetScript("OnClick",function() GS.selected=this.gsProfileIndex; GS:Refresh() end); self.buttons[i]=b end
 local save=CreateFrame("Button",nil,f,"UIPanelButtonTemplate"); save:SetWidth(145); save:SetHeight(30); save:SetPoint("BOTTOMLEFT",f,"BOTTOMLEFT",25,48); save:SetText("Enregistrer"); save:SetScript("OnClick",function() GS:Save() end)
 local apply=CreateFrame("Button",nil,f,"UIPanelButtonTemplate"); apply:SetWidth(145); apply:SetHeight(30); apply:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-25,48); apply:SetText("Appliquer"); apply:SetScript("OnClick",function() GS:Apply() end)
 local edit=CreateFrame("Button",nil,f,"UIPanelButtonTemplate"); edit:SetWidth(145); edit:SetHeight(24); edit:SetPoint("BOTTOM",f,"BOTTOM",0,112); edit:SetText("Éditer le profil"); edit:SetScript("OnClick",function() GS:OpenEditor() end)
 local rename=CreateFrame("Button",nil,f,"UIPanelButtonTemplate"); rename:SetWidth(145); rename:SetHeight(24); rename:SetPoint("BOTTOM",f,"BOTTOM",0,82); rename:SetText("Renommer le profil"); rename:SetScript("OnClick",function() GS:RenameSelected() end)
 local rf=CreateFrame("Frame","GroupSwitchRenameFrame",UIParent); rf:SetWidth(300); rf:SetHeight(145); rf:SetPoint("CENTER",UIParent,"CENTER",0,40); rf:SetFrameStrata("FULLSCREEN_DIALOG"); rf:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
 local rt=rf:CreateFontString(nil,"OVERLAY","GameFontNormal"); rt:SetPoint("TOP",rf,"TOP",0,-22); rt:SetText("Nom du profil")
 local eb=CreateFrame("EditBox","GroupSwitchRenameEditBox",rf,"InputBoxTemplate"); eb:SetWidth(220); eb:SetHeight(24); eb:SetPoint("TOP",rt,"BOTTOM",0,-18); eb:SetAutoFocus(false); eb:SetScript("OnEnterPressed",function() GS:ConfirmRename() end); eb:SetScript("OnEscapePressed",function() GroupSwitchRenameFrame:Hide() end)
 local ok=CreateFrame("Button",nil,rf,"UIPanelButtonTemplate"); ok:SetWidth(90); ok:SetHeight(24); ok:SetPoint("BOTTOMLEFT",rf,"BOTTOMLEFT",45,22); ok:SetText("Valider"); ok:SetScript("OnClick",function() GS:ConfirmRename() end)
 local cancel=CreateFrame("Button",nil,rf,"UIPanelButtonTemplate"); cancel:SetWidth(90); cancel:SetHeight(24); cancel:SetPoint("BOTTOMRIGHT",rf,"BOTTOMRIGHT",-45,22); cancel:SetText("Annuler"); cancel:SetScript("OnClick",function() GroupSwitchRenameFrame:Hide() end)
 rf:Hide()
 local foot=f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); foot:SetPoint("BOTTOM",f,"BOTTOM",0,22); foot:SetText("/gs  •  Chef de raid / assistant pour appliquer")
 f:Hide(); self.frame=f; self:Refresh()
end
function GS:Toggle() self:CreateUI(); if self.frame:IsShown() then self.frame:Hide() else self:Refresh(); self.frame:Show() end end
SLASH_GROUPSWITCH1="/gs"; SLASH_GROUPSWITCH2="/groupswitch"; SlashCmdList["GROUPSWITCH"]=function(msg) GS:Toggle() end
local ef=CreateFrame("Frame")
ef:RegisterEvent("VARIABLES_LOADED")
ef:RegisterEvent("RAID_ROSTER_UPDATE")
ef:SetScript("OnEvent",function()
 if event=="VARIABLES_LOADED" then
  EnsureDB(); GS:CreateUI()
 elseif event=="RAID_ROSTER_UPDATE" then
  if GS.applying and GS.waitingRoster then
   -- Le serveur a confirmé une modification de roster.
   -- On ne relance PAS immédiatement une autre opération :
   -- on impose une période calme afin d'éviter une rafale de roster updates.
   GS.rosterConfirmed=true
   GS.waitingRoster=false
   GS.applyTimeout=nil
   GS.applyDelay=0.75
  end
 end
end)

ef:SetScript("OnUpdate",function()
 if not GS.applying then return end

 if GS.waitingRoster then
  if GS.applyTimeout then
   GS.applyTimeout=GS.applyTimeout-arg1
   if GS.applyTimeout<=0 then
    -- Aucun event reçu : on relit quand même le roster après un délai sûr.
    GS.applyTimeout=nil
    GS.waitingRoster=false
    GS.rosterConfirmed=nil
    GS.applyDelay=0.75
   end
  end
  return
 end

 if GS.applyDelay then
  GS.applyDelay=GS.applyDelay-arg1
  if GS.applyDelay<=0 then
   GS.applyDelay=nil
   GS.rosterConfirmed=nil
   GS:ContinueApply()
  end
 end
end)
