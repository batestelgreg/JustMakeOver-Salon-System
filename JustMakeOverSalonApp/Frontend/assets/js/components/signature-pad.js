/**
 * Kani nga component kay shared signature pad para sa tanang module
 * (Requisition approval, Delivery issue, ug Delivery complete).
 *
 * Usa ra ang drawing logic aron dili ma-duplicate sa matag page.
 * Ang canvas mo-set ug `data-signed="1"` kung naay na-draw.
 */

export function createSignaturePad(canvas, options = {}) {
    if (!canvas) {
        return null;
    }

    const onChange = options.onChange || (() => {});
    let drawing = false;

    const context = canvas.getContext('2d');

    const reset = () => {
        drawing = false;
        canvas.dataset.signed = '0';

        context.fillStyle = '#ffffff';
        context.fillRect(0, 0, canvas.width, canvas.height);
        context.strokeStyle = '#1a1a1a';
        context.lineWidth = 2.2;
        context.lineCap = 'round';
        context.lineJoin = 'round';

        onChange(false);
    };

    const point = (event) => {
        const rect = canvas.getBoundingClientRect();

        return {
            x: (event.clientX - rect.left) *
                (canvas.width / rect.width),
            y: (event.clientY - rect.top) *
                (canvas.height / rect.height)
        };
    };

    canvas.addEventListener('pointerdown', (event) => {
        const p = point(event);

        drawing = true;
        canvas.dataset.signed = '1';
        canvas.setPointerCapture(event.pointerId);

        onChange(true);

        context.beginPath();
        context.moveTo(p.x, p.y);
        context.lineTo(p.x + 0.1, p.y + 0.1);
        context.stroke();
        context.beginPath();
        context.moveTo(p.x, p.y);

        event.preventDefault();
    });

    canvas.addEventListener('pointermove', (event) => {
        if (!drawing) {
            return;
        }

        const p = point(event);

        context.lineTo(p.x, p.y);
        context.stroke();
        context.beginPath();
        context.moveTo(p.x, p.y);

        event.preventDefault();
    });

    canvas.addEventListener('pointerup', () => {
        drawing = false;
    });

    canvas.addEventListener('pointercancel', () => {
        drawing = false;
    });

    reset();

    return {
        clear: reset,
        hasSignature: () => canvas.dataset.signed === '1',
        toDataURL: () => canvas.toDataURL('image/png')
    };
}
