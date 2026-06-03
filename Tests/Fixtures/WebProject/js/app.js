function calculateTotal(items) {
    return items.reduce((a, b) => a + b, 0);
}

const formatCurrency = (value) => {
    return `$${value.toFixed(2)}`;
};

class ShoppingCart {
    constructor() {
        this.items = [];
    }
    
    addItem(item) {
        this.items.push(item);
    }
}

async function fetchData(url) {
    const response = await fetch(url);
    return await response.json();
}
