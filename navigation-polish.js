/* Presentation only; preserve each original navigation handler and label. */
(() => {
  const nav=document.querySelector('.theme-admin .nav-tabs');
  if(nav){
    nav.id='adminSidebar';
    nav.querySelectorAll('.tab-btn').forEach(button=>button.setAttribute('aria-label',[...button.childNodes].filter(n=>n.nodeType===3).map(n=>n.textContent).join('').trim()));
    const toggle=document.createElement('button');toggle.type='button';toggle.className='admin-menu-toggle';toggle.textContent='☰ أقسام لوحة الإدارة';toggle.setAttribute('aria-controls',nav.id);toggle.setAttribute('aria-expanded','false');
    nav.before(toggle);
    toggle.onclick=()=>{const open=nav.classList.toggle('menu-open');toggle.setAttribute('aria-expanded',String(open));};
    nav.addEventListener('click',event=>{const button=event.target.closest('.tab-btn');if(button&&matchMedia('(max-width:760px)').matches){nav.classList.remove('menu-open');toggle.setAttribute('aria-expanded','false');toggle.focus({preventScroll:true});}});
  }
  for(const [selector,left] of [['#directoryPrevious',false],['#directoryNext',true],['#manualClose',false],['#profileBack',false],['.portal-dialog-back .portal-close',false]]){
    document.querySelectorAll(selector).forEach(button=>{const arrow=document.createElement('span');arrow.className='navigation-arrow'+(left?' left':'');arrow.setAttribute('aria-hidden','true');button.prepend(arrow);});
  }
})();
