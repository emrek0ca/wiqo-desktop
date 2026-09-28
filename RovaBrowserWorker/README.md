# Wiqo local browser worker

The companion bundles the worker and its pinned Playwright package manifest. On the first user-initiated browser task, the worker installs the locked Playwright dependency and Chromium into the current user's application-support directory. Install scripts are disabled; downloads use the package lock and Playwright's official browser installer. Later tasks reuse the installed runtime.

Node.js 20 or newer and an internet connection are required for first-use setup. The setup runs only when the browser capability is used, has a 105-second bound, and returns a safe actionable error if a prerequisite is missing or a download cannot finish. The browser and package cache stay under the current user's application-support directory; no personal browser profile is accessed.

The worker starts only for a user-initiated browser task. Each task gets a temporary browser context; closing or expiring the task removes its cookies and page state.

The companion exposes only accessible controls discovered by `observe`. Each control receives a
short task-local reference; models never send CSS selectors or JavaScript. References are invalidated
after navigation, clicks, submits, scrolling, back navigation, or a new observation. Ordinary form
fills and selections may share one observation so a multi-field form does not require a model round
per field. Password, OTP, payment, upload, login and messaging actions remain blocked.
