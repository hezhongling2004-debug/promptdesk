window.__ModuleLoader__.load({
  id: 'promptdesk-skill-labels',
  factory: () => {
    const labels = __PROMPTDESK_LABELS__;
    return {
      inject: ['inputTriggers'],
      apply(ctx) {
        const service = ctx.inputTriggers || ctx.get('inputTriggers');
        let restore;
        function attach() {
          const source = service?.live?.sources?.find(s => s.trigger === '/' && s.name === 'skill');
          if (!source || restore) return;
          const original = source.candidates;
          const wrapped = async function(session, options) {
            const query = options.query || '';
            const chineseMatch = /[^\x00-\x7f]/.test(query) || Object.values(labels).some(v => v.includes(query));
            const rows = await original.call(this, session, chineseMatch ? {...options, query: ''} : options);
            return rows.map(row => {
              const embedded = row.name.startsWith('promptdesk-') && row.description?.match(/用于「(.*?)」（/u)?.[1];
              const label = embedded || labels[row.name];
              return label ? {...row, label} : row;
            })
              .filter(row => !chineseMatch || !query || (row.label || row.name).includes(query) || row.name.includes(query));
          };
          source.candidates = wrapped;
          restore = () => { if (source.candidates === wrapped) source.candidates = original; };
        }
        attach();
        const timer = setInterval(attach, 500);
        ctx.effect(() => () => { clearInterval(timer); restore?.(); });
      }
    };
  }
});
