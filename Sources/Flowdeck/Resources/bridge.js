(() => {
  if (window.flowdeck || window !== window.top) return;
  let sequence = 0;
  const call = async (method, params = {}) => {
    const response = await window.webkit.messageHandlers.flowdeck.postMessage({
      id: String(++sequence), method, params
    });
    window.dispatchEvent(new CustomEvent('flowdeck:result', { detail: response }));
    if (response.error) {
      const error = new Error(response.error.message);
      error.code = response.error.code;
      throw error;
    }
    return response.result === undefined ? null : response.result;
  };
  Object.defineProperty(window, 'flowdeck', { value: Object.freeze({
    parameters: Object.freeze(parameters),
    getParameters: () => call('getParameters'),
    getProducts: () => call('getProducts'),
    purchase: productId => call('purchase', { productId }),
    restore: () => call('restore'),
    getEntitlements: () => call('getEntitlements'),
    requestReview: () => call('requestReview'),
    close: () => call('close'),
    openURL: url => call('openURL', { url }),
    page: name => call('page', { name }),
    click: (target = '') => call('click', { target }),
    event: (name, props = {}) => call('event', { name, props }),
    completeOnboarding: () => call('completeOnboarding')
  }), writable: false, configurable: false });
  document.addEventListener('click', event => {
    const element = event.target instanceof Element
      ? event.target.closest('[data-flowdeck-click]') : null;
    if (element) window.flowdeck.click(element.getAttribute('data-flowdeck-click')).catch(() => {});
  }, true);
})();
