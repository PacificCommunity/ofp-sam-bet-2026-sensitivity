viewer_axes <- lapply(axis_order, function(axis) {
  axis_design <- design[design$axis == axis, , drop = FALSE]
  alternatives <- series[series$key %in% axis_design$key, , drop = FALSE]
  alternatives$label <- mapply(
    public_label, alternatives$key, alternatives$label, USE.NAMES = FALSE
  )
  diagnostic_label <- paste0(unname(axis_reference_label[[axis]]), " (Diagnostic)")
  axis_diagnostic <- diagnostic
  axis_diagnostic$label <- diagnostic_label
  plot_data <- rbind(axis_diagnostic, alternatives)
  alternative_labels <- unique(alternatives$label)
  labels <- if (identical(axis, "Tag overdispersion")) {
    c(alternative_labels, diagnostic_label)
  } else {
    c(diagnostic_label, alternative_labels)
  }
  colours <- c(
    stats::setNames(axis_palette[seq_along(alternative_labels)], alternative_labels),
    stats::setNames(diagnostic_colour, diagnostic_label)
  )
  configurations <- lapply(labels, function(label) {
    values <- plot_data[plot_data$label == label, , drop = FALSE]
    list(
      label = label,
      colour = unname(colours[[label]]),
      diagnostic = any(values$is_diagnostic %in% TRUE),
      year = as.integer(values$year),
      depletion = round(values$depletion, 8),
      recruitment = round(values$recruitment, 6),
      spawning_potential = round(values$spawning_potential, 6),
      fishing_mortality = round(values$fishing_mortality, 8)
    )
  })
  list(
    axis = unname(axis_display_label[[axis]]),
    changed_component = unname(axis_short_change[[axis]]),
    configurations = configurations
  )
})

viewer_json <- jsonlite::toJSON(
  viewer_axes,
  auto_unbox = TRUE,
  digits = 9,
  na = "null",
  pretty = FALSE
)

viewer_html <- paste0(
  "<!doctype html><html><head><meta charset='utf-8'>",
  "<meta name='viewport' content='width=device-width,initial-scale=1'>",
  "<title>BET 2026 sensitivity interactive viewer</title><style>",
  ":root{--ink:#172b3a;--blue:#103c56;--teal:#176c80;--paper:#fff;--grid:#dfe7eb}",
  "*{box-sizing:border-box}body{margin:0;background:#edf3f5;color:var(--ink);font-family:Arial,sans-serif}",
  "header{padding:20px 4vw;background:var(--blue);color:#fff}header h1{margin:0;font:700 29px Georgia,serif}",
  "header p{margin:7px 0 0;color:#d7e8ef}main{max-width:1500px;margin:18px auto;padding:0 18px 30px}",
  ".controls{display:grid;grid-template-columns:minmax(260px,420px) 1fr;gap:18px;background:#fff;border:1px solid #cbd9de;padding:16px;margin-bottom:16px}",
  "label strong{display:block;margin-bottom:6px}select{width:100%;padding:9px;border:1px solid #91a9b4;background:#fff;font-size:15px}",
  ".models{display:flex;align-items:center;flex-wrap:wrap;gap:8px 14px}.model{display:inline-flex;align-items:center;gap:6px;font-size:13px;white-space:nowrap}",
  ".swatch{width:22px;height:4px;border-radius:2px}.actions{display:flex;gap:7px;margin-top:9px}",
  "button{border:0;background:var(--teal);color:#fff;font-weight:700;padding:7px 10px;cursor:pointer}",
  ".note{grid-column:1/-1;margin:0;color:#49636f;font:14px/1.45 Georgia,serif}",
  ".grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}",
  ".panel{background:#fff;border:1px solid #cbd9de;padding:9px}.panel h2{margin:2px 7px 0;font:700 16px Georgia,serif;color:var(--blue)}",
  "svg{display:block;width:100%;height:auto}.axis{stroke:#425862;stroke-width:1}.gridline{stroke:var(--grid);stroke-width:1}.tick{fill:#425862;font:12px Georgia,serif}.ylabel{fill:var(--ink);font:700 13px Georgia,serif}.lrp{stroke:#b64040;stroke-width:1.5;stroke-dasharray:6 5}.lrptext{fill:#b64040;font:700 12px Georgia,serif}",
  ".footer{margin-top:16px;color:#526a75;font:13px/1.5 Georgia,serif}",
  "@media(max-width:850px){.controls,.grid{grid-template-columns:1fr}.note{grid-column:1}.controls{gap:12px}}",
  "</style></head><body><header><h1>BET 2026 sensitivity analysis</h1>",
  "<p>Interactive comparison of 17 one-at-a-time fits with the Diagnostic configuration</p></header>",
  "<main><section class='controls'><label><strong>Sensitivity axis</strong><select id='axis'></select></label>",
  "<div><strong>Configurations</strong><div id='models' class='models'></div>",
  "<div class='actions'><button id='all'>Show all</button><button id='diagnostic'>Diagnostic only</button></div></div>",
  "<p id='note' class='note'></p></section><section id='charts' class='grid'></section>",
  "<p class='footer'>All series are annual estimates reconstructed from checksum-locked completed outputs. Each alternative changes only the selected component and was fitted independently from an ordinary makepar-generated initial PAR. No MFCL fit is run by this viewer.</p></main>",
  "<script>const payload=", viewer_json, ";",
  "const specs=[",
  "{key:'depletion',title:'Dynamic spawning depletion',ylabel:'SB / SB(F=0)',lrp:true},",
  "{key:'recruitment',title:'Recruitment',ylabel:'Recruitment (millions)'},",
  "{key:'spawning_potential',title:'Spawning potential',ylabel:'Spawning potential (10³ MT)'},",
  "{key:'fishing_mortality',title:'Fishing mortality',ylabel:'F (year⁻¹)'}];",
  "const axis=document.getElementById('axis'),models=document.getElementById('models'),charts=document.getElementById('charts'),note=document.getElementById('note');",
  "payload.forEach((x,i)=>{const o=document.createElement('option');o.value=i;o.textContent=x.axis;axis.appendChild(o)});let selected=new Set();",
  "function el(name,attrs={},text=''){const x=document.createElementNS('http://www.w3.org/2000/svg',name);Object.entries(attrs).forEach(([k,v])=>x.setAttribute(k,v));if(text)x.textContent=text;return x}",
  "function setAxis(){const item=payload[+axis.value];selected=new Set(item.configurations.map(x=>x.label));models.innerHTML='';item.configurations.forEach(s=>{const lab=document.createElement('label');lab.className='model';const cb=document.createElement('input');cb.type='checkbox';cb.checked=true;cb.onchange=()=>{cb.checked?selected.add(s.label):selected.delete(s.label);draw()};const sw=document.createElement('span');sw.className='swatch';sw.style.background=s.colour;lab.append(cb,sw,document.createTextNode(s.label));models.appendChild(lab)});note.textContent='Changed component: '+item.changed_component+'. All other Diagnostic settings are retained.';draw()}",
  "function chart(spec,item){const box=document.createElement('article');box.className='panel';const h=document.createElement('h2');h.textContent=spec.title;const svg=el('svg',{viewBox:'0 0 720 330',role:'img','aria-label':spec.title});box.append(h,svg);const visible=item.configurations.filter(s=>selected.has(s.label));const vals=visible.flatMap(s=>s[spec.key]).filter(Number.isFinite);const ymax=Math.max(spec.lrp?0.22:0,...vals)*1.06||1;const m={l:78,r:18,t:15,b:48},w=720-m.l-m.r,hgt=330-m.t-m.b,x0=1952,x1=2024;const sx=x=>m.l+(x-x0)/(x1-x0)*w,sy=y=>m.t+hgt-y/ymax*hgt;",
  "for(let i=0;i<=4;i++){const y=ymax*i/4,py=sy(y);svg.append(el('line',{x1:m.l,y1:py,x2:m.l+w,y2:py,class:'gridline'}));svg.append(el('text',{x:m.l-9,y:py+4,'text-anchor':'end',class:'tick'},ymax<2?y.toFixed(2):Math.round(y).toLocaleString()))}for(const yr of [1960,1980,2000,2020]){const px=sx(yr);svg.append(el('line',{x1:px,y1:m.t,x2:px,y2:m.t+hgt,class:'gridline'}));svg.append(el('text',{x:px,y:m.t+hgt+21,'text-anchor':'middle',class:'tick'},yr))}svg.append(el('line',{x1:m.l,y1:m.t+hgt,x2:m.l+w,y2:m.t+hgt,class:'axis'}));svg.append(el('line',{x1:m.l,y1:m.t,x2:m.l,y2:m.t+hgt,class:'axis'}));svg.append(el('text',{x:m.l+w/2,y:323,'text-anchor':'middle',class:'ylabel'},'Year'));const yl=el('text',{x:18,y:m.t+hgt/2,'text-anchor':'middle',transform:`rotate(-90 18 ${m.t+hgt/2})`,class:'ylabel'},spec.ylabel);svg.append(yl);if(spec.lrp){const py=sy(.2);svg.append(el('line',{x1:m.l,y1:py,x2:m.l+w,y2:py,class:'lrp'}));svg.append(el('text',{x:m.l+7,y:py-6,class:'lrptext'},'LRP'))}visible.forEach(s=>{let d='';s.year.forEach((yr,i)=>{const v=s[spec.key][i];if(Number.isFinite(v))d+=(d?'L':'M')+sx(yr).toFixed(2)+','+sy(v).toFixed(2)});const p=el('path',{d,fill:'none',stroke:s.colour,'stroke-width':s.diagnostic?3.2:2.1,'stroke-opacity':s.diagnostic?1:.88,'stroke-linejoin':'round','stroke-linecap':'round'});p.append(el('title',{},s.label));svg.append(p)});return box}",
  "function draw(){const item=payload[+axis.value];charts.innerHTML='';specs.forEach(s=>charts.appendChild(chart(s,item)))}axis.onchange=setAxis;document.getElementById('all').onclick=()=>{models.querySelectorAll('input').forEach(x=>x.checked=true);selected=new Set(payload[+axis.value].configurations.map(x=>x.label));draw()};document.getElementById('diagnostic').onclick=()=>{const item=payload[+axis.value];selected=new Set(item.configurations.filter(x=>x.diagnostic).map(x=>x.label));models.querySelectorAll('label').forEach((lab,i)=>lab.querySelector('input').checked=item.configurations[i].diagnostic);draw()};setAxis();",
  "</script></body></html>"
)

viewer_file <- file.path(output_dir, "bet-2026-sensitivity-interactive-viewer.html")
writeLines(viewer_html, viewer_file, useBytes = TRUE)
