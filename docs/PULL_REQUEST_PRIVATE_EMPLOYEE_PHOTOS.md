# Private employee photos — review candidate

Employee photos become private and are displayed through actor-authorized signed URLs. The shared client fetches with no-store and a unique CDN cacheNonce, displays blob URLs, and invalidates pending work on logout. Uploads store object paths, retain2MiB/MIME limits, and support Storage permission-probe/multipart metadata.

Contains the original scoped private-photo migration, a separately reviewed upload-policy correction, frozen Edge dependencies, isolated regression tests and minimal fresh-install helper prerequisites/grants. Historical migrations are not rewritten. This PR is separate from Trusted Device enrollment work.

Staging: https://albashir-staging.vercel.app, Supabase adwvokwucotohwayorgx. Actual binary/multipart JPG1MiB and PNG2MiB upload/decode passed; private URL denial, IDOR, original-link expiry, resolver no-store headers and unique download nonces were tested. The owner reported registration submission success on Chrome desktop and Safari iPhone16e. Hosted admin checks verified two pending submitted requests and both photo displays. Only a synthetic request was approved through the dashboard.

Content validation policy: owner explicitly accepts administrator review. Forged MIME is not automatically rejected; no content-decoding PASS is claimed. Original Storage Cache-Control was not changed; no-store/blob/unique-nonce client mitigation is implemented and verified. Detailed results: docs/EMPLOYEE_PHOTOS_STAGING_RESULTS.md.

Validation: local npm test PASS; git diff --check PASS; hosted Staging tests PASS as individually scoped above. CI workflow is included but remote CI is not yet claimed. No Production SQL, merge or Production frontend rollout is authorized by this PR. Review and apply backend prerequisites separately before any Production frontend deployment.
