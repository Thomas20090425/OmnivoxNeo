import Foundation

/// The hard-coded facts about MIO — OmniVox's internal messaging.
///
/// MIO is a third product again after the portal and Léa: its own module path,
/// its own session, and a genuine frameset — a toolbar frame, a folder-menu
/// frame, and a middle frame that is itself a frameset holding the list and
/// the open message. Everything a script needs to find its way around that is
/// declared here rather than written into the scripts.
///
/// The values that matter most are the **icon file names**. MIO writes every
/// meaningful state as a picture: whether a message is unread, replied to or
/// sent, and whether the other person is a student, a teacher or an
/// administrator. The words under those pictures are translated; the file names
/// are not. Reading `mio_MessageNonLu.svg` works in French, reading "New
/// message" works only in English.
struct MioConventions: Sendable, Equatable {
    // MARK: Reaching MIO

    /// The shortcut on the portal home that hops into MIO.
    ///
    /// Followed rather than rebuilt: the redirect mints the MIO session, and a
    /// hand-made address arrives without one.
    var portalShortcutSelector: String =
        #"a.code-groupe_mio, a[class*="code-groupe_mio"], a[href*="RedirigeMio"], a[href*="IdService=MIOE"]"#

    /// Recognises that MIO has finished opening. Any one of these is enough:
    /// the frameset, the folder menu, or the list itself.
    var readySelector: String = #"frame[name="frGauche"], frame[name="frMilieu"], table.lstMIO, #container"#

    /// The module's own path, which every other address is built under.
    var modulePathFragment: String = "/WebApplication/Module.MIOE"
    var listPath: String = "/Commun/Message/MioListe.aspx"
    var detailPath: String = "/Commun/Message/MioDetail.aspx"
    var composePath: String = "/Commun/Composer/NouveauMessage.ashx"
    /// The frameset whose `src` carries the session parameters worth copying.
    var framesetPathFragment: String = "MioListeDetailFrameset.aspx"
    /// And its own address.
    ///
    /// Reading a list works perfectly well from the bare list page, because
    /// that arrives as finished HTML. *Pressing* something on it does not: the
    /// scripts that put MIO's click handlers on the flags are loaded by the
    /// frameset around it, so on the page by itself the controls are pictures
    /// of controls. Anything that changes something goes through here.
    var framesetPath: String = "/Commun/Message/MioListeDetailFrameset.aspx"

    /// Query names MIO addresses things by.
    var folderQueryName: String = "NomCategorie"
    var messageQueryName: String = "m"
    var detailFolderQueryName: String = "categorie"
    var composeActionQueryName: String = "Action"
    var composeMessageQueryName: String = "IdMessage"

    // MARK: The folder menu

    /// Every folder link in the left frame carries its token in its own id:
    /// `lnkCat_SEARCH_FOLDER_MioRecu`.
    var folderLinkSelector: String = #"a[id^="lnkCat_"]"#
    var folderLinkIDPrefix: String = "lnkCat_"

    /// What a link has to point at to be a folder rather than an errand.
    ///
    /// The same menu holds "Manage categories" and "Favourite contacts", which
    /// carry the same kind of id and are not places mail lives. Told apart by
    /// where they go — a folder's link names a folder — rather than by their
    /// labels, which are translated.
    var folderLinkRequiredFragment: String = "NomCategorie"

    /// Which folder a token means, matched as a case-insensitive fragment of
    /// the token so a build that spells the rest of it differently still lands.
    ///
    /// Anything unmatched is a folder the student made, which is not a failure
    /// — it is shown under its own name with a plain folder symbol.
    var folderKinds: [String: String] = [
        "MioRecu": "inbox",
        "Recu": "inbox",
        "Inbox": "inbox",
        "MioEnvoi": "sent",
        "Envoi": "sent",
        "Envoy": "sent",
        "Sent": "sent",
        "Brouillon": "drafts",
        "Drapeau": "flagged",
        "Categorise": "categorised",
        "Corbeille": "deleted",
        "Supprime": "deleted"
    ]

    /// The token for the inbox, for opening on something sensible before the
    /// menu has been read.
    var inboxFolderKey: String = "SEARCH_FOLDER_MioRecu"

    // MARK: The message list

    var listTableSelector: String = "table.lstMIO"
    var listRowSelector: String = #"tr[id^="tr"]"#
    /// MIO's class for a row it wants noticed — new, or marked to read again.
    var unreadRowClass: String = "newmsg"
    var senderSelector: String = "td.name .msgUser"
    var subjectCellSelector: String = "td.lsTdTitle"
    /// The subject is the emphasised run at the front of that cell; everything
    /// after it is the preview.
    var subjectSelector: String = "em"
    var dateSelector: String = "td.date span"
    var attachmentSizeSelector: String = "td.fileSize"
    var flagSelector: String = ".drapeaux"
    var flagOnClass: String = "drapeaux-on"
    /// MIO's "to read again" dot, which the student sets themselves.
    var followUpSelector: String = ".pastille-indicateur"
    var followUpOnClass: String = "pastille-relire-on"
    /// Carries the bare message id on both of those.
    var messageIDAttribute: String = "data-message"
    /// `1` on a row in a sent folder.
    var isSentAttribute: String = "data-ismioenvoi"
    var stateIconSelector: String = "td.stateIcon"
    var correspondentIconSelector: String = "td.identityIcon"
    var readReceiptSelector: String = "td.lectures"
    /// MIO hides the column entirely when there is nothing to report.
    var readReceiptEmptyClass: String = "lectures-vide"
    var categorySelector: String = "td.categorie a"
    /// The category's own name, which is empty when the message has none.
    ///
    /// Read from here rather than from the link's text: MIO draws the same
    /// link either way, and an uncategorised message reads as being filed
    /// under "Categorize" — the name of the button, in English, on every row.
    var categoryNameAttribute: String = "data-nomcomplet"
    var totalSelector: String = "#totalMio"
    /// Every row's checkbox is `chk` followed by the token MIO addresses the
    /// message by — the id with the sent flag on the end. The same token is in
    /// a JavaScript array on the page, but reading it from the markup means not
    /// depending on a global variable surviving a post-back.
    var rowCheckboxSelector: String = #"input[type="checkbox"][id^="chk"]"#
    var rowCheckboxIDPrefix: String = "chk"

    /// What MIO's state icons are called, and what each one means.
    var stateIcons: [String: String] = [
        "mio_MessageNonLu": "unread",
        "mio_MessageLu": "read",
        "mio_Reply": "replied",
        "mio_ReplyAll": "replied",
        "mio_Envoyer": "sent"
    ]

    /// And its badges for who the other person is.
    var correspondentIcons: [String: String] = [
        "mio_Type1": "student",
        "mio_Type2": "employee",
        "mio_Type3": "manager"
    ]

    /// The paperclip.
    var attachmentIconName: String = "mio_PieceJointe"

    // MARK: One message

    /// MIO's detail page lays one message out as a table of labelled rows —
    /// `From`, `To`, `Date`, the subject, then the body — each with its own
    /// class. Read off the live page rather than guessed at; the guesses all
    /// missed, and what the app showed instead was the whole page with its own
    /// header printed twice.
    var detailWrapperSelector: String = "table.Msg, .fullViewWrapper"
    var detailSubjectSelector: String = "td.cSujet"
    var detailSenderSelector: String = "td.cDe"
    var detailRecipientSelector: String = #"td.cA, td[id$="tdACont"]"#
    var detailDateSelector: String = "td.cDate"
    /// The body's own wrapper inside the body cell. Preferred over the cell so
    /// the message arrives without the table row around it.
    var detailBodySelector: String = #"#contenuWrapper, [id$="contenuWrapper"], td.cBody"#
    var detailAttachmentSelector: String =
        #"a[href*="Attachement"], a[href*="PieceJointe"], a[href*="Telecharger"], a[href*="Download"]"#

    // MARK: Writing one

    var composeSubjectSelector: String = #"[id$="txtSujet"]"#
    /// The editor's own textarea, which is what actually gets posted. Writing
    /// into it and letting MIO's control read it back is far steadier than
    /// typing into the editor's iframe.
    var composeBodySelector: String =
        #"[id$="txtMioNouveau"], [id$="ftbMioNouveauContentHiddenTextarea"], textarea[name$="ftbMioNouveau"]"#
    /// The editor around that textarea, for the builds that keep the text a
    /// student can see in a separate editable element.
    var composeEditorWrapperSelector: String = #"#teleWrap, [id$="teleWrap"], .divEditeurMio"#
    /// The editor control's own client id, for handing it the text through its
    /// own API when that is available.
    var composeEditorID: String = "ctl00_cntFormulaire_ftbMioNouveau"
    /// MIO's own Send, and the order matters.
    ///
    /// The visible link comes first because pressing it runs the page's own
    /// `CheckCanSendMessage()` — which validates, copies the editor's content
    /// into the field that actually gets posted, strips what it will not carry
    /// and cancels the auto-save — before it posts back. The hidden post-back
    /// input at the end does the posting *without* any of that, so reaching it
    /// first would send a message that had skipped every check MIO makes.
    var composeSendSelector: String = #"#hlkSend, [id$="hlkSend"], a.hlkSend, [id$="btnSend"]"#
    var composeSaveDraftSelector: String =
        #"#hlkDraft, [id$="hlkDraft"], a.hlkDraft, [id$="btnSauvegarder"]"#
    /// MIO greys its own controls out rather than disabling them.
    var composeDisabledClass: String = "disabled"

    /// Where MIO prints the people it has been handed.
    ///
    /// **Not** the row below it, which is where this used to look. That one
    /// holds the controls — a link, a quick-find box, and two captions reading
    /// "Search all available recipients" and "Search for a recipient" — and
    /// reading names out of it put MIO's own button labels in the To field as
    /// though they were people.
    var composeRecipientRowSelector: String = #"[id$="trDestinataire"]"#
    /// The controls row, named so it can be excluded rather than mistaken.
    var composeRecipientControlsSelector: String = #"[id$="trAjoutDestinataires"]"#
    var composeRecipientPickerSelector: String = #"[id$="lnkRecherche"], [id$="ImglnkRecherche"]"#
    var composeHideRecipientsSelector: String = #"[id$="ckbMasquer"]"#
    var composeAttachSelector: String =
        #"#hlkAttach, a.hlkAttach, [id$="hlkAttach"], a.lnkJoindreFichier, [id$="hlkAttachImg"]"#
    /// How the upload window is told apart from the recipient picker: both
    /// arrive as `window.open`, and they are completely different screens.
    var composeUploadPathFragment: String = "NouveauMessage_Upload"
    /// Where MIO lists what is already attached.
    var composeAttachmentRowSelector: String = #"#lstFichiersJoints, [id$="trFichiersJoints"]"#
    /// One attached file: a wrapper holding an icon, the name in its own `<p>`,
    /// the size as loose text, and a bin.
    var composeAttachmentSelector: String = ".fichiersJointsWrapper"
    var composeAttachmentNameSelector: String = "p"
    /// And how it offers to take one off again — a post-back carrying the
    /// file's own id, so it is pressed rather than reconstructed.
    var composeAttachmentRemoveSelector: String =
        #"a[href*="btnActionDelete"], a[href*="Delete"], [onclick*="Suppr"], .lnkSupprimer"#
    /// MIO's own confirmation that the message went.
    var composeSentConfirmationSelector: String = #"[id$="confirmEnvoi_divConfirmNoSave"]"#
    var confirmationShownClass: String = "affConfirm"

    // MARK: Choosing who it goes to

    /// MIO's recipient picker, which it opens in a window of its own.
    ///
    /// It is three screens behind one address: a menu of ways to find somebody,
    /// a browser of the student's own classes, and a search across the college.
    /// Which one is currently showing is told from which container is on the
    /// page rather than from its heading, which is translated.
    var pickerPanelSelector: String = #"#updPanel, [id$="updPanel"], .BorderLegende"#
    var pickerTitleSelector: String = ".TexteLegende"
    var pickerInstructionsSelector: String =
        ".instructionsPageCategorie, .instructionsPageCategorieFullWidth, .titrePageCategories"

    /// The menu of ways in, and the little headings that group them.
    var pickerChooserSelector: String = ".divContainerLiensCategories"
    var pickerOptionSelector: String = ".ListeRegroupementsDisponibles_RegroupementItemMenu"
    var pickerOptionGroupSelector: String = ".ListeRegroupementsDisponibles_Categorie_Titre"

    /// Browsing the student's own classes.
    var pickerGroupsSelector: String = ".divContainerCategories"
    var pickerGroupSelector: String = "#ListeCategories > .Categorie"
    var pickerGroupTitleSelector: String = ".TitreExpand"
    var pickerGroupSubtitleSelector: String = ".coursGroupe"
    var pickerGroupExpandSelector: String = ".LienExpandCollapse"
    var pickerGroupExpandedClass: String = "Collapse"
    var pickerGroupAddAllSelector: String = ".AjouterEtudiants"
    var pickerGroupMembersSelector: String = ".SousItems"
    var pickerGroupEmptySelector: String = ".AucunIndividu"

    /// The term and campus menus above that list.
    var pickerFilterSelector: String = ".divfiltre"
    var pickerFilterLabelSelector: String = ".lblFiltre"

    /// One person, wherever they are listed — in a search result, in a class,
    /// or in the panel of people already chosen.
    ///
    /// Matched on the exact class rather than on a fragment: a *class* carries
    /// `LayoutItemSelectionEtudiantCours`, and anything looser offers a course
    /// section as though it were a person.
    var pickerPersonSelector: String = ".LayoutItemSelection"
    /// The headings MIO files those under — "Employee", "Teacher", "Student".
    /// Read so they can be shown as what somebody *is* rather than listed as
    /// somebody you can write to, which is what happened before.
    var pickerPersonHeadingSelector: String = ".TitreTypeItem, .titreSectionDestinataireSelectionner"
    /// MIO writes who somebody is into the class name itself.
    var pickerPersonRoleClasses: [String: String] = [
        "LayoutItemSelection_Employe": "employee",
        "LayoutItemSelection_Enseignant": "employee",
        "LayoutItemSelection_Etudiant": "student",
        "LayoutItemSelection_Gestionnaire": "manager"
    ]

    /// Searching the college by name.
    var pickerSearchSelector: String = ".divContainerRecherche"
    var pickerSearchFieldSelector: String = ".txtRecherche"
    var pickerSearchButtonSelector: String = ".btnRecherche"
    var pickerSearchResultsSelector: String = "#divRecherche"
    var pickerSearchEmptySelector: String = "#divAucunIndividuRecherche"
    var pickerSearchOverflowSelector: String = "#divTropResultats"
    var pickerBusySelector: String = "#divRechercheEnCours, .Chargement"

    /// Who has been chosen so far, which MIO keeps in a panel of its own.
    var pickerSelectionSelector: String = #"#tdAffichageIndividuSelectionne, [id$="tdAffichageIndividuSelectionne"]"#
    var pickerSelectionSectionSelector: String = "#divEmploye, #divEnseignant, #divEtudiant, #divClasse, #divAutre"
    var pickerSelectionTitleSelector: String = ".titreSectionDestinataireSelectionner"
    var pickerSelectionListSelector: String = ".listeIndividus"
    var pickerSelectionEmptySelector: String = "#divAucunIndividuSelectionne"

    /// One person in that panel, and the cross that takes them off again.
    ///
    /// Read off the live page rather than assumed, after three attempts at
    /// inferring it. A chosen person is **`.ItemSelectionne`** — not
    /// `.LayoutItemSelection`, which is what MIO uses in *results* — and the
    /// name sits as a bare text node beside the control:
    ///
    ///     <div class="listeIndividus">
    ///       <div class="ItemSelectionne"><span class="Supprimer">   </span>Ma, Thomas</div>
    ///     </div>
    ///
    /// The control is a **`<span>`**. No href, no onclick, no `<a>` and no
    /// `<img>` — which is why a search for "anything clickable" inside the row
    /// came back empty and every removal was refused as unresolvable.
    var pickerSelectionItemSelector: String = ".ItemSelectionne"
    var pickerSelectionRemoveSelector: String =
        #".Supprimer, [class*="Supprim"], [class*="supprim"]"#

    /// "You can send a Mio to a maximum of 75 recipients." MIO's own number,
    /// printed rather than assumed — it is a college setting, not a constant.
    var pickerWarningSelector: String = ".lblWarning"

    /// What finishes the picker and hands the choice back to the form.
    ///
    /// Several candidates because this is a footer the app has to recognise
    /// rather than one it draws. If none of them match, the picker's own page
    /// is shown instead of a dead button.
    var pickerCommitSelector: String =
        #"[id$="btnSauvegarder"], [id$="btnEnregistrer"], [id$="btnOK"], [id$="btnAjouter"], .btnSauvegarder, #btnSauvegarder"#
    var pickerCancelSelector: String =
        #"[id$="btnAnnuler"], [id$="btnFermer"], .btnAnnuler, #btnAnnuler"#

    /// MIO's own way back from a search or a class list to the menu.
    ///
    /// Worth having rather than closing and reopening: the selection so far
    /// lives on MIO's side, and starting over is not the same as going back.
    var pickerBackSelector: String =
        #"[id$="lnkRetour"], .LienRetour, #lnkRetour"#

    // MARK: Throwing one away

    /// MIO's own Delete on the list toolbar, read off the live page.
    ///
    /// It acts on whatever is ticked: `if(IsItemChecked()) …`. Greyed out
    /// through a class rather than disabled, so it is there and findable
    /// whether or not anything is selected.
    ///
    /// Named exactly, after a version of this that tried to *recognise* a
    /// delete control by matching "anything whose icon file is called
    /// something like Supprimer" got it comprehensively wrong: MIO draws the
    /// **No** button of the delete confirmation with `mio_Supprimer.svg`, so
    /// the first thing that ranking pressed, every time, was the button that
    /// cancels the delete.
    var deleteControlSelector: String = #"#hlkDelete, [id$="hlkDelete"], a.hlkDelete, a.hlkDeleteGray"#

    /// The box it raises — "Delete the selected messages? Yes / No".
    ///
    /// Same machinery as the send confirmation: `MsgConfirmation_*` swaps
    /// `hideConfirm` for `affConfirm` on the panel, so whether it is up is
    /// read from the class rather than from layout.
    var deleteConfirmSelector: String =
        #"[id$="confirmDelete_divConfirmNoSave"], [id*="confirmDelete"][id*="divConfirm"]"#
    var deleteConfirmHiddenClass: String = "hideConfirm"

    /// And the Yes on it.
    ///
    /// MIO draws that one button as three overlapping anchors — an icon, a
    /// label and a wrapper — which all carry the *same* id and the same
    /// `javascript:` href, so any of them will do. The No beside it has no id
    /// at all, which is what keeps this from finding it.
    var deleteConfirmAcceptSelector: String = #"[id$="divConfirmNoSave_default"]"#

    // MARK: Flags and follow-ups

    /// MIO changes both of these with a small web-service call rather than a
    /// page load, which is why the app can change them without leaving the list.
    var indicatorServicePath: String = "/Commun/Message/SetEtatIndicateur.asmx"
    var followUpMethod: String = "ChangeIndicateurARelire"
    var flagMethod: String = "ChangeIndicateurDrapeaux"

    /// The page's own functions for these, named so they can be called rather
    /// than approximated.
    ///
    /// Pressing the control was not enough, and the reason is worth writing
    /// down. MIO's handler does two things in order: it updates the picture,
    /// and *then* it sends the request that changes the message. The part that
    /// updates the picture also reaches sideways into the folder-menu frame to
    /// adjust the count beside "Flagged" — and this app reads MIO's pages on
    /// their own, where there is no such frame. So that first step threw, the
    /// request never ran, and a flag set in the app was simply gone the next
    /// time the portal was opened. Nothing reported it, because from the
    /// page's point of view a click handler raised and was swallowed.
    ///
    /// The fix is to call the same function with the count-updating step
    /// stubbed out for the length of the call. The app re-reads the row from a
    /// fresh page afterwards, so the picture was never what it was relying on.
    var indicatorBindFunction: String = "bindClickIndicateur"
    var flagChangeFunction: String = "ChangerEtatIndicateurDrapeaux"
    var followUpChangeFunction: String = "ChangerEtatIndicateurARelire"
    var flagToggleFunction: String = "toggleDrapeaux"
    var followUpToggleFunction: String = "toggleARelire"

    static let omnivoxStock = MioConventions()

    /// The subset the in-page scripts need, as a JSON object literal.
    var javascriptDescriptor: String {
        let strings: [String: Any] = [
            "ready": readySelector,
            "folderLink": folderLinkSelector,
            "folderPrefix": folderLinkIDPrefix,
            "folderRequired": folderLinkRequiredFragment,
            "folderKinds": folderKinds,
            "listTable": listTableSelector,
            "listRow": listRowSelector,
            "unreadRowClass": unreadRowClass,
            "sender": senderSelector,
            "subjectCell": subjectCellSelector,
            "subject": subjectSelector,
            "date": dateSelector,
            "attachmentSize": attachmentSizeSelector,
            "flag": flagSelector,
            "flagOn": flagOnClass,
            "followUp": followUpSelector,
            "followUpOn": followUpOnClass,
            "messageIDAttribute": messageIDAttribute,
            "isSentAttribute": isSentAttribute,
            "stateIcon": stateIconSelector,
            "correspondentIcon": correspondentIconSelector,
            "readReceipt": readReceiptSelector,
            "readReceiptEmpty": readReceiptEmptyClass,
            "category": categorySelector,
            "categoryName": categoryNameAttribute,
            "total": totalSelector,
            "rowCheckbox": rowCheckboxSelector,
            "checkboxPrefix": rowCheckboxIDPrefix,
            "stateIcons": stateIcons,
            "correspondentIcons": correspondentIcons,
            "attachmentIcon": attachmentIconName,
            "detailWrapper": detailWrapperSelector,
            "detailSubject": detailSubjectSelector,
            "detailSender": detailSenderSelector,
            "detailRecipient": detailRecipientSelector,
            "detailDate": detailDateSelector,
            "detailBody": detailBodySelector,
            "detailAttachment": detailAttachmentSelector,
            "composeSubject": composeSubjectSelector,
            "composeBody": composeBodySelector,
            "composeEditorWrapper": composeEditorWrapperSelector,
            "composeRecipientControls": composeRecipientControlsSelector,
            "composeEditorID": composeEditorID,
            "pickerPerson": pickerPersonSelector,
            "pickerPersonHeading": pickerPersonHeadingSelector,
            "pickerPersonRoles": pickerPersonRoleClasses,
            "composeSend": composeSendSelector,
            "composeSaveDraft": composeSaveDraftSelector,
            "composeDisabled": composeDisabledClass,
            "composeRecipientRow": composeRecipientRowSelector,
            "composeRecipientPicker": composeRecipientPickerSelector,
            "composeHideRecipients": composeHideRecipientsSelector,
            "composeAttach": composeAttachSelector,
            "composeAttachmentRow": composeAttachmentRowSelector,
            "composeAttachment": composeAttachmentSelector,
            "composeAttachmentName": composeAttachmentNameSelector,
            "composeAttachmentRemove": composeAttachmentRemoveSelector,
            "composeSentConfirmation": composeSentConfirmationSelector,
            "confirmationShown": confirmationShownClass,
            "framesetFragment": framesetPathFragment,
            "modulePath": modulePathFragment,
            "pickerPanel": pickerPanelSelector,
            "pickerTitle": pickerTitleSelector,
            "pickerInstructions": pickerInstructionsSelector,
            "pickerChooser": pickerChooserSelector,
            "pickerOption": pickerOptionSelector,
            "pickerOptionGroup": pickerOptionGroupSelector,
            "pickerGroups": pickerGroupsSelector,
            "pickerGroup": pickerGroupSelector,
            "pickerGroupTitle": pickerGroupTitleSelector,
            "pickerGroupSubtitle": pickerGroupSubtitleSelector,
            "pickerGroupExpand": pickerGroupExpandSelector,
            "pickerGroupExpanded": pickerGroupExpandedClass,
            "pickerGroupAddAll": pickerGroupAddAllSelector,
            "pickerGroupMembers": pickerGroupMembersSelector,
            "pickerGroupEmpty": pickerGroupEmptySelector,
            "pickerFilter": pickerFilterSelector,
            "pickerFilterLabel": pickerFilterLabelSelector,
            "pickerSearch": pickerSearchSelector,
            "pickerSearchField": pickerSearchFieldSelector,
            "pickerSearchButton": pickerSearchButtonSelector,
            "pickerSearchResults": pickerSearchResultsSelector,
            "pickerSearchEmpty": pickerSearchEmptySelector,
            "pickerSearchOverflow": pickerSearchOverflowSelector,
            "pickerBusy": pickerBusySelector,
            "pickerSelection": pickerSelectionSelector,
            "pickerSelectionSection": pickerSelectionSectionSelector,
            "pickerSelectionTitle": pickerSelectionTitleSelector,
            "pickerSelectionList": pickerSelectionListSelector,
            "pickerSelectionEmpty": pickerSelectionEmptySelector,
            "pickerSelectionItem": pickerSelectionItemSelector,
            "pickerSelectionRemove": pickerSelectionRemoveSelector,
            "pickerWarning": pickerWarningSelector,
            "pickerCommit": pickerCommitSelector,
            "pickerCancel": pickerCancelSelector,
            "pickerBack": pickerBackSelector,
            "deleteControl": deleteControlSelector,
            "deleteConfirm": deleteConfirmSelector,
            "deleteConfirmHidden": deleteConfirmHiddenClass,
            "deleteConfirmAccept": deleteConfirmAcceptSelector,
            "indicatorBind": indicatorBindFunction,
            "flagChange": flagChangeFunction,
            "followUpChange": followUpChangeFunction,
            "flagToggle": flagToggleFunction,
            "followUpToggle": followUpToggleFunction
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: strings, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }
}
