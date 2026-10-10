/* ALBASHIR ui-components.js v1.0 — display helpers only. No Supabase, no QR, no auth decisions. */
(function (w) {
  function badge(state) {
    var s = String(state || "").toUpperCase();
    return '<span class="alb-badge ' + s + '">' + s + "</span>";
  }
  function alertBox(kind, msg) {
    return '<div class="alb-alert ' + kind + '">' + msg + "</div>";
  }
  var activeModal = null, previousFocus = null, scrollPosition = 0, bodyStyle = "";
  function finishModal(m) {
    if (activeModal !== m) return;
    m.classList.remove("open");
    if (m.id === "portalLoginOverlay") m.classList.add("portal-login-overlay--closed");
    m.setAttribute("aria-hidden", "true");
    document.body.style.cssText = bodyStyle;
    document.documentElement.classList.remove("alb-modal-locked");
    activeModal = null;
    w.scrollTo({top: scrollPosition, behavior: "instant"});
    if (previousFocus && previousFocus.isConnected) previousFocus.focus({preventScroll:true});
  }
  function openModal(id) {
    var m = document.getElementById(id); if (!m || activeModal === m) return;
    if (activeModal) closeModal(activeModal.id);
    previousFocus = document.activeElement; scrollPosition = w.scrollY;
    bodyStyle = document.body.style.cssText; activeModal = m;
    document.documentElement.classList.add("alb-modal-locked");
    Object.assign(document.body.style, {position:"fixed", top:-scrollPosition+"px", width:"100%", overflow:"hidden"});
    m.classList.remove("portal-login-overlay--closed"); m.classList.add("open");
    m.setAttribute("aria-hidden", "false");
    if (m.tagName === "DIALOG") {
      if (!m.dataset.modalBound) {
        m.addEventListener("cancel", function(e) { e.preventDefault(); closeModal(m.id); });
        // A queued close event may arrive after a rapid reopen (notably WebKit).
        m.addEventListener("close", function() { if (!m.open) finishModal(m); });
        m.dataset.modalBound = "true";
      }
      m.showModal();
    }
  }
  function closeModal(id) {
    var m = document.getElementById(id); if (!m) return;
    if (m.tagName === "DIALOG" && m.open) m.close();
    finishModal(m);
  }
  function markInvalid(fieldId, on) {
    var f = document.getElementById(fieldId);
    if (f && f.closest) f.closest(".alb-field").classList.toggle("invalid", !!on);
  }
  function bindFileName(inputId, labelId) {
    var i = document.getElementById(inputId), l = document.getElementById(labelId);
    if (i && l) i.addEventListener("change", function () { l.textContent = (i.files && i.files[0] && i.files[0].name) || ""; });
  }
  w.ALBASHIR_UI = { badge: badge, alertBox: alertBox, openModal: openModal, closeModal: closeModal, markInvalid: markInvalid, bindFileName: bindFileName };
})(window);
