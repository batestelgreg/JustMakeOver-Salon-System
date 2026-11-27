/**
 * Kani nga shared component kay para sa hardened digital signing:
 * - Signature pad (createSignaturePad)
 * - Signer identity preview (Name + Role)
 * - Mandatory confirmation checkbox ("I confirm this signature...")
 * - Multi-stage signature manager modal (view/verify/sign/Admin revoke)
 *
 * Gigamit ni sa PO approval, Receiving Report (Checked), Stock Card
 * (Prepared/Custodian), ug Replenishment Request (Requested/Approved).
 */
import { invoke } from '../core/bridge.js';
import { getUser, hasPermission } from '../core/state.js';
import { createSignaturePad } from './signature-pad.js';
import { showToast } from './toast.js';
import { formatPrintDate } from './print-document.js';

/**
 * Kani nga function kay nag-open ug reusable signature confirmation dialog.
 * Mo-resolve sa `{ signature, confirmed: true }` kung gi-confirm, o `null`
 * kung gi-cancel.
 */
export function openSignatureDialog(options = {}) {
    return new Promise((resolve) => {
        const user = getUser();
        const signerLabel = user
            ? `${user.fullName || user.username || 'Current user'} (${user.role || 'User'})`
            : 'Authenticated user';

        const overlay = document.createElement('div');
        overlay.className = 'modal-overlay';
        overlay.setAttribute('role', 'dialog');
        overlay.setAttribute('aria-modal', 'true');

        overlay.innerHTML = `
            <div class="modal" style="width: min(520px, calc(100vw - 48px));">
                <div class="modal__header">
                    <h3 class="modal__title"></h3>
                    <button type="button" class="modal__close" data-sig-close aria-label="Close">&times;</button>
                </div>
                <div class="modal__body">
                    <p class="u-text-muted u-mb-4" data-sig-message style="margin-top: 0;"></p>
                    <p class="signature-signer-meta" data-sig-actor></p>
                    <div class="signature-validation-box u-hidden" data-sig-error role="alert"></div>
                    <div class="signature-pad">
                        <div class="signature-pad__header">
                            <span class="signature-pad__label" data-sig-stage></span>
                            <button type="button" class="btn btn--ghost btn--sm" data-sig-clear>Clear</button>
                        </div>
                        <canvas class="signature-pad__canvas" width="600" height="200" aria-label="Digital signature pad"></canvas>
                    </div>
                    <label class="signature-confirm-check">
                        <input type="checkbox" data-sig-confirm>
                        <span data-sig-confirm-text></span>
                    </label>
                    <p class="u-text-muted" style="font-size: 12px; margin: 8px 0 0;">
                        Your name, role, timestamp, and a snapshot hash of this document will be recorded.
                        This is an internal digital approval record (not a PKI/legal certificate).
                    </p>
                </div>
                <div class="modal__footer">
                    <button type="button" class="btn btn--ghost" data-sig-cancel>Cancel</button>
                    <button type="button" class="btn btn--primary" data-sig-submit></button>
                </div>
            </div>
        `;

        overlay.querySelector('.modal__title').textContent =
            options.title || 'Digital Signature Required';
        overlay.querySelector('[data-sig-message]').textContent =
            options.message || 'Draw your signature below to sign this record.';
        overlay.querySelector('[data-sig-actor]').textContent =
            'Signing as: ' + signerLabel;
        overlay.querySelector('[data-sig-stage]').textContent =
            options.stageLabel || 'Authorized signature';
        overlay.querySelector('[data-sig-confirm-text]').textContent =
            options.confirmLabel
            || 'I confirm this signature and understand that this record will be locked after signing.';
        overlay.querySelector('[data-sig-submit]').textContent =
            options.submitText || 'Confirm & Sign';

        document.body.appendChild(overlay);

        const canvas = overlay.querySelector('canvas');
        const checkbox = overlay.querySelector('[data-sig-confirm]');
        const submitBtn = overlay.querySelector('[data-sig-submit]');
        const errorBox = overlay.querySelector('[data-sig-error]');

        const showValidation = (msg) => {
            if (!errorBox) return;
            if (!msg) {
                errorBox.textContent = '';
                errorBox.classList.add('u-hidden');
            } else {
                errorBox.textContent = msg;
                errorBox.classList.remove('u-hidden');
            }
        };

        let pad = null;
        let settled = false;

        const close = (result) => {
            if (settled) return;
            settled = true;
            document.removeEventListener('keydown', onKeyDown);
            overlay.remove();
            resolve(result);
        };

        const onKeyDown = (event) => {
            if (event.key === 'Escape') {
                close(null);
            }
        };
        document.addEventListener('keydown', onKeyDown);

        overlay.querySelector('[data-sig-close]').addEventListener('click', () => close(null));
        overlay.querySelector('[data-sig-cancel]').addEventListener('click', () => close(null));
        overlay.addEventListener('click', (event) => {
            if (event.target === overlay) {
                close(null);
            }
        });

        pad = createSignaturePad(canvas, {
            onChange: (signed) => {
                if (signed) {
                    showValidation('');
                }
            }
        });

        checkbox.addEventListener('change', () => {
            if (checkbox.checked) {
                showValidation('');
            }
        });

        overlay.querySelector('[data-sig-clear]').addEventListener('click', () => {
            pad?.clear();
            showValidation('');
        });

        submitBtn.addEventListener('click', () => {
            if (!pad?.hasSignature()) {
                showValidation('Please draw your signature in the pad above before confirming.');
                return;
            }
            if (!checkbox.checked) {
                showValidation('Please check the confirmation box ("I confirm this signature...") before saving.');
                checkbox.focus();
                return;
            }
            close({
                signature: pad.toDataURL(),
                confirmed: true
            });
        });
    });
}

/**
 * Kani nga helper kay nag-open ug multi-stage signature modal para sa
 * standalone signable internal records (Stock Card, Replenishment Request,
 * Receiving Report Checked-by). Makita dinhi ang existing signatures,
 * hash integrity status, ug pwede mo-sign ang user nga may permission.
 */
export async function openDocumentSignManager(options) {
    const {
        documentType,
        documentID,
        documentTitle,
        stages = [],
        onChanged = null
    } = options;

    const user = getUser();
    const isAdmin = String(user?.role || '').toLowerCase() === 'admin';

    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-modal', 'true');

    overlay.innerHTML = `
        <div class="modal" style="width: min(620px, calc(100vw - 48px));">
            <div class="modal__header">
                <h3 class="modal__title"></h3>
                <button type="button" class="modal__close" data-mgr-close aria-label="Close">&times;</button>
            </div>
            <div class="modal__body">
                <p class="u-text-muted u-mb-4" data-mgr-subtitle style="margin-top: 0;"></p>
                <div data-mgr-list class="signature-stage-list">Loading signatures&hellip;</div>
            </div>
            <div class="modal__footer">
                <button type="button" class="btn btn--ghost" data-mgr-done>Close</button>
            </div>
        </div>
    `;

    overlay.querySelector('.modal__title').textContent =
        'Digital Signatures — ' + (documentTitle || documentType);
    overlay.querySelector('[data-mgr-subtitle]').textContent =
        'Internal digital sign-offs are bound to this document snapshot hash and locked after signing.';

    document.body.appendChild(overlay);

    const close = () => overlay.remove();
    overlay.querySelector('[data-mgr-close]').addEventListener('click', close);
    overlay.querySelector('[data-mgr-done]').addEventListener('click', close);
    overlay.addEventListener('click', (event) => {
        if (event.target === overlay) close();
    });

    const listHost = overlay.querySelector('[data-mgr-list]');

    async function loadAndRender() {
        listHost.innerHTML = '<p class="u-text-muted">Loading signatures&hellip;</p>';
        try {
            const result = await invoke('DocumentSignatureGet', {
                documentType,
                documentID: String(documentID)
            });

            const activeList = result?.signatures || [];
            const byStage = new Map(
                activeList.map((sig) => [String(sig.Stage || '').toLowerCase(), sig])
            );

            listHost.innerHTML = '';

            stages.forEach((stageDef) => {
                const sig = byStage.get(String(stageDef.stage).toLowerCase());
                const allowedPerms = stageDef.permissions || [];
                const canSign = allowedPerms.length === 0
                    || allowedPerms.some((code) => hasPermission(code));

                const card = document.createElement('div');
                card.className = 'signature-stage-card';

                const header = document.createElement('div');
                header.className = 'signature-stage-card__header';

                const titleEl = document.createElement('strong');
                titleEl.textContent = stageDef.label;
                header.appendChild(titleEl);

                const badge = document.createElement('span');
                if (sig) {
                    const hashValid = sig.IsHashValid === true || sig.IsHashValid === 1;
                    badge.className = 'badge ' + (hashValid ? 'badge--success' : 'badge--pending');
                    badge.textContent = hashValid
                        ? 'Signed & Locked'
                        : (documentType === 'STOCK_CARD' ? 'Snapshot updated' : 'Hash mismatch');
                } else {
                    badge.className = 'badge badge--neutral';
                    badge.textContent = 'Not signed';
                }
                header.appendChild(badge);
                card.appendChild(header);

                if (sig) {
                    const hashValid = sig.IsHashValid === true || sig.IsHashValid === 1;
                    const meta = document.createElement('p');
                    meta.className = 'signature-stage-card__meta';
                    meta.textContent =
                        `Digitally signed by ${sig.SignerName} (${sig.SignerRole}) on ${formatPrintDate(sig.SignedAt, true)}`
                        + (sig.DocumentHash ? ` · Hash ${String(sig.DocumentHash).slice(0, 12)}` : '');
                    card.appendChild(meta);

                    if (sig.SignatureImage && String(sig.SignatureImage).startsWith('data:image/')) {
                        const img = document.createElement('img');
                        img.className = 'signature-stage-card__preview';
                        img.src = sig.SignatureImage;
                        img.alt = stageDef.label + ' signature';
                        card.appendChild(img);
                    }

                    const actions = document.createElement('div');
                    actions.className = 'signature-stage-card__actions';

                    if (documentType === 'STOCK_CARD' && !hashValid && canSign) {
                        const resignBtn = document.createElement('button');
                        resignBtn.type = 'button';
                        resignBtn.className = 'btn btn--secondary btn--sm';
                        resignBtn.textContent = 'Re-sign current snapshot';
                        resignBtn.addEventListener('click', () => handleSignStage(stageDef));
                        actions.appendChild(resignBtn);
                    }

                    if (isAdmin) {
                        const revokeBtn = document.createElement('button');
                        revokeBtn.type = 'button';
                        revokeBtn.className = 'btn btn--danger btn--sm';
                        revokeBtn.textContent = 'Revoke (Admin)';
                        revokeBtn.addEventListener('click', () => handleRevoke(sig));
                        actions.appendChild(revokeBtn);
                    }

                    if (actions.childNodes.length > 0) {
                        card.appendChild(actions);
                    }
                } else {
                    const emptyText = document.createElement('p');
                    emptyText.className = 'u-text-muted';
                    emptyText.style.margin = '4px 0 8px';
                    emptyText.style.fontSize = '13px';
                    emptyText.textContent = canSign
                        ? 'Pending digital signature for this stage.'
                        : 'You do not have permission to sign this stage.';
                    card.appendChild(emptyText);

                    if (canSign) {
                        const signBtn = document.createElement('button');
                        signBtn.type = 'button';
                        signBtn.className = 'btn btn--primary btn--sm';
                        signBtn.textContent = 'Sign as ' + stageDef.label;
                        signBtn.addEventListener('click', () => handleSignStage(stageDef));
                        card.appendChild(signBtn);
                    }
                }

                listHost.appendChild(card);
            });
        } catch (error) {
            listHost.innerHTML = '';
            const err = document.createElement('p');
            err.className = 'form-field__error';
            err.textContent = error.message || 'Unable to load signatures.';
            listHost.appendChild(err);
        }
    }

    async function handleSignStage(stageDef) {
        const result = await openSignatureDialog({
            title: 'Sign ' + (documentTitle || documentType),
            message: `Sign the "${stageDef.label}" stage for ${documentTitle || documentType}.`,
            stageLabel: stageDef.label + ' signature',
            submitText: 'Confirm & Sign'
        });

        if (!result) return;

        try {
            await invoke('DocumentSignatureSign', {
                documentType,
                documentID: String(documentID),
                stage: stageDef.stage,
                signatureImage: result.signature,
                confirmed: 'true'
            });
            showToast('success', `${stageDef.label} signature saved and locked.`);
            await loadAndRender();
            if (typeof onChanged === 'function') {
                onChanged();
            }
        } catch (error) {
            showToast('error', error.message || 'Unable to save signature.');
        }
    }

    async function handleRevoke(sig) {
        const reason = await openRevokeReasonDialog(sig);
        if (!reason) return;

        try {
            await invoke('DocumentSignatureRevoke', {
                signatureID: String(sig.SignatureID),
                reason
            });
            showToast('success', 'Signature revoked and logged to audit trail.');
            await loadAndRender();
            if (typeof onChanged === 'function') {
                onChanged();
            }
        } catch (error) {
            showToast('error', error.message || 'Unable to revoke signature.');
        }
    }

    await loadAndRender();
}

function openRevokeReasonDialog(sig) {
    return new Promise((resolve) => {
        const overlay = document.createElement('div');
        overlay.className = 'modal-overlay';
        overlay.innerHTML = `
            <div class="modal" style="width: min(460px, calc(100vw - 48px));">
                <div class="modal__header">
                    <h3 class="modal__title">Revoke Signature (Admin)</h3>
                    <button type="button" class="modal__close" data-rv-close aria-label="Close">&times;</button>
                </div>
                <div class="modal__body">
                    <p class="u-text-muted u-mb-4" style="margin-top:0;">
                        Revoking preserves the original signature in the audit trail and unlocks the stage for re-signing.
                    </p>
                    <div class="form-field">
                        <label class="form-field__label" for="txtRevokeReason">Reason for revoking (required)</label>
                        <textarea id="txtRevokeReason" class="form-field__input" rows="3" maxlength="500"
                                  placeholder="Explain why this signature is being revoked..."></textarea>
                        <span class="form-field__error" data-rv-err></span>
                    </div>
                </div>
                <div class="modal__footer">
                    <button type="button" class="btn btn--ghost" data-rv-cancel>Cancel</button>
                    <button type="button" class="btn btn--danger" data-rv-submit>Revoke Signature</button>
                </div>
            </div>
        `;
        document.body.appendChild(overlay);

        const textarea = overlay.querySelector('#txtRevokeReason');
        const err = overlay.querySelector('[data-rv-err]');
        const close = (val) => {
            overlay.remove();
            resolve(val);
        };

        overlay.querySelector('[data-rv-close]').addEventListener('click', () => close(null));
        overlay.querySelector('[data-rv-cancel]').addEventListener('click', () => close(null));
        overlay.addEventListener('click', (e) => { if (e.target === overlay) close(null); });
        overlay.querySelector('[data-rv-submit]').addEventListener('click', () => {
            const val = textarea.value.trim();
            if (!val) {
                err.textContent = 'A revoke reason is required.';
                textarea.focus();
                return;
            }
            close(val);
        });
        textarea.focus();
    });
}

/**
 * Kani nga helper kay nag-find sa active signature sa print payload
 * pinaagi sa stage name (case-insensitive).
 */
export function findStageSignature(signatures, stageName) {
    if (!Array.isArray(signatures) || !stageName) {
        return null;
    }
    const target = String(stageName).toLowerCase();
    return signatures.find((sig) => String(sig?.Stage || '').toLowerCase() === target) || null;
}

/**
 * Kani nga helper kay nag-convert sa stored DOCUMENT_SIGNATURES row
 * ngadto sa print-document.js signature block descriptor.
 */
export function toPrintSignatureBlock(sig, fallbackLabel, fallbackName = ' ') {
    if (sig && sig.SignatureImage && String(sig.SignatureImage).startsWith('data:image/')) {
        return {
            name: sig.SignerName || fallbackName,
            role: sig.SignerRole || '',
            label: sig.StageLabel || fallbackLabel,
            image: sig.SignatureImage,
            date: sig.SignedAt,
            documentHash: sig.DocumentHash || '',
            isHashValid: sig.IsHashValid !== false && sig.IsHashValid !== 0,
            isDigital: true
        };
    }

    return {
        name: fallbackName || ' ',
        label: fallbackLabel,
        handwritten: false
    };
}
