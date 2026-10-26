package com.example.ordermanager.model;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;

import java.math.BigDecimal;
import java.util.Objects;

@Embeddable
public class OrderItem {

    @Column(name = "product_name", nullable = false, length = 150)
    private String productName;

    @Column(name = "quantity", nullable = false)
    private int quantity;

    @Column(name = "unit_price", nullable = false, precision = 10, scale = 2)
    private BigDecimal unitPrice;

    public OrderItem() {}

    public OrderItem(String productName, int quantity, BigDecimal unitPrice) {
        if (productName == null || productName.isBlank()) {
            throw new IllegalArgumentException("El nombre del producto es obligatorio");
        }
        if (quantity <= 0) {
            throw new IllegalArgumentException("La cantidad debe ser mayor a 0");
        }
        if (unitPrice == null || unitPrice.signum() < 0) {
            throw new IllegalArgumentException("El precio unitario no puede ser negativo");
        }
        this.productName = productName.trim();
        this.quantity = quantity;
        this.unitPrice = unitPrice;
    }

    public BigDecimal getSubtotal() {
        return unitPrice.multiply(BigDecimal.valueOf(quantity));
    }

    public String getProductName() { return productName; }
    public void setProductName(String productName) { this.productName = productName; }
    public int getQuantity() { return quantity; }
    public void setQuantity(int quantity) { this.quantity = quantity; }
    public BigDecimal getUnitPrice() { return unitPrice; }
    public void setUnitPrice(BigDecimal unitPrice) { this.unitPrice = unitPrice; }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (o == null || getClass() != o.getClass()) return false;
        OrderItem that = (OrderItem) o;
        return quantity == that.quantity
                && Objects.equals(productName, that.productName)
                && Objects.equals(unitPrice, that.unitPrice);
    }

    @Override
    public int hashCode() {
        return Objects.hash(productName, quantity, unitPrice);
    }
}
