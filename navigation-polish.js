/* Presentation only; preserve each original navigation handler and label. */
(() => {
  const nav=document.querySelector('.theme-admin .nav-tabs');
  if(nav){
    nav.id='adminSidebar';
    nav.querySelectorAll('.tab-btn').forEach(button=>button.setAttribute('aria-label',[...button.childNodes].filter(n=>n.nodeType===3).map(n=>n.textContent).join('').trim()));
    const toggle=document.createElement('button');toggle.type='button';toggle.className='admin-menu-toggle';toggle.textContent='☰ أقسام لوحة الإدارة';toggle.setAttribute('aria-controls',nav.id);toggle.setAttribute('aria-expanded','false');
    nav.before(toggle);
    const controls=document.createElement('div');controls.className='admin-section-navigation';
    const previous=document.createElement('button'),next=document.createElement('button'),title=document.createElement('span');
    previous.type=next.type='button';previous.innerHTML='<span class="navigation-arrow" aria-hidden="true"></span>القسم السابق';next.innerHTML='القسم التالي<span class="navigation-arrow left" aria-hidden="true"></span>';
    title.setAttribute('aria-live','polite');controls.append(previous,title,next);nav.after(controls);
    const tabs=[...nav.querySelectorAll('.tab-btn')];
    const original=window.showTab;
    function refresh(){const active=document.querySelector('.section.active');const i=tabs.findIndex(b=>(b.getAttribute('onclick')||'').includes("'"+active?.id+"'"));previous.disabled=i<=0;next.disabled=i<0||i===tabs.length-1;title.textContent=tabs[i]?.getAttribute('aria-label')||'';return i;}
    window.showTab=function(id,button){original(id,button||tabs.find(b=>(b.getAttribute('onclick')||'').includes("'"+id+"'")));refresh();};
    previous.onclick=()=>{const i=refresh();if(i>0)tabs[i-1].click();};next.onclick=()=>{const i=refresh();if(i>=0&&i<tabs.length-1)tabs[i+1].click();};refresh();
    toggle.onclick=()=>{const open=nav.classList.toggle('menu-open');toggle.setAttribute('aria-expanded',String(open));};
    nav.addEventListener('click',event=>{const button=event.target.closest('.tab-btn');if(button&&matchMedia('(max-width:760px)').matches){nav.classList.remove('menu-open');toggle.setAttribute('aria-expanded','false');toggle.focus({preventScroll:true});}});
  }
  for(const [selector,left] of [['#directoryPrevious',false],['#directoryNext',true],['#manualClose',false],['#profileBack',false],['.portal-dialog-back .portal-close',false]]){
    document.querySelectorAll(selector).forEach(button=>{const arrow=document.createElement('span');arrow.className='navigation-arrow'+(left?' left':'');arrow.setAttribute('aria-hidden','true');button.prepend(arrow);});
  }
})();
